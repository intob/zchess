//! Playing-strength limit (UCI_LimitStrength / UCI_Elo, `zchess play --elo`).
//!
//! Lower ratings get a smaller search, more candidate moves (MultiPV) and a
//! weighted random choice between them: p(line) ∝ exp((score - best) / T).
//! At the bottom the temperature T is large enough that hanging a piece is a
//! real possibility; at 3000 it plays its best move. The mapping is a first
//! guess, calibrated from 1320 up against Stockfish's limiter (its minimum);
//! below that it is extrapolated.

const std = @import("std");
const search = @import("search.zig");

pub const MIN_ELO = 100;
pub const MAX_ELO = 3000;

pub const Params = struct {
    nodes: u64,
    lines: usize,
    temperature: f64, // centipawns
};

/// Calibration: requested rating -> internal setting, from matches against
/// Stockfish 19's limiter at 10+0.1 (2026-10-08, gen6w with continuation
/// history, 300 games per point: internal 1211 played like ~1407, internal
/// 1630 like ~1981 and internal 2052 like ~2727, each ±39). Linear between
/// points; below 1407 extrapolated. Stronger nets or search shift the table:
/// re-measure with scripts/remote-calibrate.sh after a promotion.
const calibration = [_][2]f64{
    .{ 100, 300 },
    .{ 1407, 1211 },
    .{ 1981, 1630 },
    .{ 2727, 2052 },
    .{ 3000, 3000 },
};

fn internalElo(requested: f64) f64 {
    for (calibration[1..], 1..) |hi, i| {
        const lo = calibration[i - 1];
        if (requested <= hi[0]) return lo[1] + (requested - lo[0]) * (hi[1] - lo[1]) / (hi[0] - lo[0]);
    }
    return calibration[calibration.len - 1][1];
}

pub fn params(elo: u32) Params {
    const e: f64 = internalElo(@floatFromInt(std.math.clamp(elo, MIN_ELO, MAX_ELO)));
    const t = (e - MIN_ELO) / (MAX_ELO - MIN_ELO); // 0 at the bottom, 1 at the top
    const nodes = 50.0 * std.math.pow(f64, 40_000.0, t); // 50 .. 2M
    const lines = 1.0 + 19.0 * (1.0 - t) * (1.0 - t); // 20 .. 1
    const temperature = 600.0 * @exp(-4.8 * t); // 600 cp .. 5 cp
    return .{
        .nodes = @intFromFloat(@round(nodes)),
        .lines = @min(@as(usize, @intFromFloat(@round(lines))), search.MAX_MULTIPV),
        .temperature = if (elo >= MAX_ELO) 0 else temperature,
    };
}

pub const Choice = struct {
    result: search.Result,
    /// Index into s.lines of the chosen line (0 = the engine's best).
    line: usize,
};

/// Search at the strength of `elo` and pick a move as described above.
/// `clock` carries the time limits of the game (soft_ms / hard_ms); the
/// search stops at whichever comes first, the clock or the node budget.
pub fn choose(s: *search.Searcher, rng: std.Random, elo: u32, clock: search.Limits) Choice {
    const p = params(elo);
    const saved = s.multipv;
    defer s.multipv = saved;
    s.multipv = p.lines;
    var limits = clock;
    limits.soft_nodes = p.nodes;
    limits.nodes = p.nodes * 4;
    const r = s.search(limits);
    if (s.n_lines <= 1 or p.temperature <= 0) return .{ .result = r, .line = 0 };

    // Mate scores would swamp the weights; clamp them to a big but finite edge.
    const clampScore = struct {
        fn f(x: i32) f64 {
            return @floatFromInt(std.math.clamp(x, -2000, 2000));
        }
    }.f;
    const best = clampScore(s.lines[0].score);
    var weights: [search.MAX_MULTIPV]f64 = undefined;
    var total: f64 = 0;
    for (s.lines[0..s.n_lines], 0..) |line, i| {
        weights[i] = @exp((clampScore(line.score) - best) / p.temperature);
        total += weights[i];
    }
    var x = rng.float(f64) * total;
    for (weights[0..s.n_lines], 0..) |w, i| {
        x -= w;
        if (x <= 0) {
            const line = s.lines[i];
            return .{ .result = .{ .move = line.move, .score = line.score, .depth = r.depth }, .line = i };
        }
    }
    return .{ .result = r, .line = 0 };
}

test "strength parameters are monotonic" {
    var prev = params(MIN_ELO);
    var elo: u32 = MIN_ELO + 100;
    while (elo <= MAX_ELO) : (elo += 100) {
        const cur = params(elo);
        try std.testing.expect(cur.nodes >= prev.nodes);
        try std.testing.expect(cur.lines <= prev.lines);
        try std.testing.expect(cur.temperature <= prev.temperature);
        prev = cur;
    }
    try std.testing.expectEqual(@as(f64, 0), params(MAX_ELO).temperature);
}

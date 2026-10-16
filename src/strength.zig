//! Playing-strength limit (UCI_LimitStrength / UCI_Elo, `zchess play --elo`).
//!
//! Lower ratings get a smaller search, more candidate moves (MultiPV) and a
//! weighted random choice between them: p(line) ∝ natural(move) ·
//! exp((score - best) / T). At the bottom the temperature T is large enough
//! that hanging a piece is a real possibility; at 3000 it plays its best move.
//!
//! To play like a person rather than a weakened engine, the weight also says
//! how natural the move looks (`natural`): recaptures, captures, checks,
//! saving an attacked piece, developing and castling come first; king walks,
//! moving a piece straight back, rook shuffles and early queen trips last.
//! So it errs the way people do, missing what's deeper (a tactic, a piece
//! that only looked safe) rather than playing pointless moves. In the first
//! moves it plays what strong players play (the coach's opening book),
//! weighted by how often, for as many moves as a player of that rating knows
//! (`bookPlies`).
//!
//! The mapping is a first guess, calibrated from 1320 up against Stockfish's
//! limiter (its minimum); below that it is extrapolated.

const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const tactics = @import("tactics.zig");
const openings = @import("openings.zig");

const Position = position.Position;
const Move = position.Move;

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

/// Choosing natural moves (`natural`, and the book) is worth this much
/// against the plain weighted choice the calibration above was measured
/// with (old vs new at UCI_Elo 1400, 200 games: +102 ± 51), so the rating
/// asked for is lowered by it first.
const NATURAL_ELO = 100;

pub fn params(elo: u32) Params {
    const asked: f64 = @floatFromInt(std.math.clamp(elo, MIN_ELO, MAX_ELO));
    const e: f64 = internalElo(if (elo >= MAX_ELO) asked else @max(asked - NATURAL_ELO, MIN_ELO));
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
    /// Index into s.lines of the chosen line (0 = the engine's best); null
    /// for a book move (no search).
    line: ?usize,
};

/// Book moves played at `elo`: about 3 moves each at the bottom, 12 at 2700.
pub fn bookPlies(elo: u32) usize {
    return 6 + elo / 150;
}

/// A position counts as book with this many games (as for the coach).
const BOOK_GAMES = 20;
/// Moves played in under this share (percent) of them aren't picked.
const BOOK_MIN_PCT = 3;

fn bookMove(pos: *const Position, game: []const Move, elo: u32, rng: std.Random) ?Move {
    const book = openings.Book.embeddedBook() orelse return null;
    // Only from the start position, and while the game is short enough.
    if (pos.fullmove > 1 + bookPlies(elo) / 2 or game.len >= bookPlies(elo)) return null;
    const ms = book.moves(pos.key);
    const total = ms.total();
    if (total < BOOK_GAMES) return null;
    var pick = rng.uintLessThan(u64, total);
    var chosen: ?Move = null;
    for (0..ms.len()) |i| {
        const e = ms.get(i);
        if (pick < e.games()) {
            chosen = e.move;
            break;
        }
        pick -= e.games();
    }
    const m = chosen orelse return null;
    // Rare sidelines are the moves people don't know; take the main one.
    for (0..ms.len()) |i| {
        const e = ms.get(i);
        if (e.move.eql(m)) return if (e.games() * 100 >= BOOK_MIN_PCT * total) m else ms.get(0).move;
    }
    return m;
}

/// How natural `m` looks to a person in `pos` (a weight around 1), with
/// `game` the moves so far (the last one the opponent's).
pub fn natural(pos: *const Position, m: Move, game: []const Move) f64 {
    const us = pos.side;
    const from = m.from();
    const to = m.to();
    const pt = bb.pieceType(pos.board[from]);
    const opening = pos.fullmove <= 12;
    const last: ?Move = if (game.len >= 1) game[game.len - 1] else null;
    const own_last: ?Move = if (game.len >= 2) game[game.len - 2] else null;
    var w: f64 = 1;

    if (m.isCapture()) {
        // Taking back is a reflex; other captures are what people look at first.
        w *= if (last != null and last.?.isCapture() and last.?.to() == to) 4 else 2;
    }
    if (m.isPromotion()) w *= 3;
    if (pos.makeMove(m).inCheck()) w *= 1.5;
    // A piece under attack gets moved (people see that one).
    if (tactics.loosePieces(pos, us) & bb.bit(from) != 0) w *= 3;
    if (m.isCastle()) w *= 4;
    const back: u64 = if (us == bb.WHITE) 0xff else 0xff << 56;
    if (opening and (pt == bb.KNIGHT or pt == bb.BISHOP) and bb.bit(from) & back != 0) w *= 2;
    if (opening and pt == bb.PAWN and !m.isCapture() and (bb.fileOf(from) == 3 or bb.fileOf(from) == 4)) w *= 1.5;

    if (m.isCapture() or pos.inCheck()) return w;
    // Quiet moves people rarely play.
    const queens = pos.pieces[bb.QUEEN] != 0;
    if (pt == bb.KING and !m.isCastle() and queens) w *= 0.5;
    if (own_last) |o| {
        if (o.from() == to and o.to() == from) w *= 0.5; // straight back
        if (o.to() == from and pt == bb.ROOK) w *= 0.7; // the same rook again
        if (o.to() == from and opening and tactics.loosePieces(pos, us) & bb.bit(from) == 0) w *= 0.5;
    }
    if (pt == bb.QUEEN and pos.fullmove < 8) w *= 0.5;
    if (pt == bb.ROOK and opening and pos.castling != 0) w *= 0.5;
    if (pt == bb.KNIGHT and (bb.fileOf(to) == 0 or bb.fileOf(to) == 7)) w *= 0.6;
    if (pt == bb.PAWN and opening and (bb.fileOf(from) == 0 or bb.fileOf(from) == 7)) w *= 0.7;
    return w;
}

/// Search at the strength of `elo` and pick a move as described above:
/// `pos` is the position searched (s's root) and `game` the moves that led
/// to it. `clock` carries the time limits of the game (soft_ms / hard_ms);
/// the search stops at whichever comes first, the clock or the node budget.
pub fn choose(s: *search.Searcher, rng: std.Random, elo: u32, clock: search.Limits, pos: *const Position, game: []const Move) Choice {
    if (elo < MAX_ELO) if (bookMove(pos, game, elo, rng)) |m| return .{ .result = .{ .move = m, .score = 0, .depth = 0 }, .line = null };
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
        weights[i] = natural(pos, line.move, game) * @exp((clampScore(line.score) - best) / p.temperature);
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

test "natural moves: recaptures first, king walks and moving back last" {
    const atk = @import("attacks.zig");
    atk.init();
    const movegen = @import("movegen.zig");
    // 1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bxc6: dxc6 (taking back) over Ke7.
    var p = Position.startpos();
    var game: [7]Move = undefined;
    for ([_][]const u8{ "e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5c6" }, 0..) |u, i| {
        game[i] = movegen.parseUci(&p, u).?;
        p = p.makeMove(game[i]);
    }
    const take = natural(&p, movegen.parseUci(&p, "d7c6").?, &game);
    const king = natural(&p, movegen.parseUci(&p, "e8e7").?, &game);
    const quiet = natural(&p, movegen.parseUci(&p, "h7h6").?, &game);
    try std.testing.expect(take > 3 * quiet);
    try std.testing.expect(king < quiet);
    // After 5. Nc3 Nf6 (a knight out), Nf6-g8 straight back is unlikely.
    var q = Position.fromFen("r1bqkb1r/1pp2ppp/p1p2n2/4p3/4P3/2N2N2/PPPP1PPP/R1BQK2R b KQkq - 1 5") catch unreachable;
    const g8 = movegen.parseUci(&q, "f6g8").?;
    const own = Move.init(62, 45, Move.QUIET); // ...Ng8-f6, the move before
    const hist = [_]Move{ own, Move.none };
    try std.testing.expect(natural(&q, g8, &hist) < 0.5 * natural(&q, movegen.parseUci(&q, "f8d6").?, &hist));
}

test "book moves in the opening" {
    const atk = @import("attacks.zig");
    atk.init();
    if (openings.Book.embeddedBook() == null) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(1);
    const start = Position.startpos();
    var seen = [_]u32{0} ** 4;
    for (0..200) |_| {
        const m = bookMove(&start, &.{}, 1400, prng.random()) orelse return error.TestUnexpectedResult;
        var buf: [5]u8 = undefined;
        const u = m.toUci(&buf);
        for ([_][]const u8{ "e2e4", "d2d4", "g1f3", "c2c4" }, 0..) |x, i| if (std.mem.eql(u8, u, x)) {
            seen[i] += 1;
        };
    }
    // Mostly 1. e4 and 1. d4, and nothing outside the usual first moves.
    try std.testing.expect(seen[0] > 40 and seen[1] > 40);
    try std.testing.expect(seen[0] + seen[1] + seen[2] + seen[3] >= 190);
    // Not past the moves a 1400 player knows.
    var deep = start;
    deep.fullmove = 20;
    try std.testing.expect(bookMove(&deep, &.{}, 1400, prng.random()) == null);
}

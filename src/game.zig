//! Shared game-playing helpers for self-play data generation and matches.

const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const search = @import("search.zig");

const Position = position.Position;

pub const Outcome = enum { white, black, draw };

/// Play `plies` uniformly random legal moves from the start position.
/// Returns null if the game ended along the way.
pub fn randomOpening(rng: std.Random, plies: usize) ?Position {
    var pos = Position.startpos();
    for (0..plies) |_| {
        var list = movegen.MoveList{};
        movegen.generate(&pos, &list, .all);
        if (list.len == 0) return null;
        pos = pos.makeMove(list.moves[rng.uintLessThan(usize, list.len)]);
    }
    var list = movegen.MoveList{};
    movegen.generate(&pos, &list, .all);
    if (list.len == 0) return null;
    return pos;
}

/// Rules-based game end: mate, stalemate, 50-move rule, insufficient
/// material, threefold repetition. `keys` holds earlier positions' hashes.
pub fn terminal(pos: *const Position, keys: []const u64) ?Outcome {
    var list = movegen.MoveList{};
    movegen.generate(pos, &list, .all);
    if (list.len == 0) {
        if (!pos.inCheck()) return .draw;
        return if (pos.side == bb.WHITE) .black else .white;
    }
    if (pos.halfmove >= 100 or pos.isInsufficientMaterial()) return .draw;
    var reps: usize = 0;
    var i: usize = 2;
    while (i <= pos.halfmove and i <= keys.len) : (i += 2) {
        if (keys[keys.len - i] == pos.key) reps += 1;
    }
    if (reps >= 2) return .draw;
    return null;
}

/// Ends clearly decided games early to save compute.
pub const Adjudicator = struct {
    win_plies: u32 = 0,
    win_sign: i32 = 0,
    draw_plies: u32 = 0,

    pub const win_score = 1500;
    pub const win_needed = 6;
    pub const draw_score = 10;
    pub const draw_needed = 12;
    pub const draw_after_ply = 80;
    pub const max_ply = 500;

    /// `white_score` is the latest search score from white's point of view.
    pub fn update(a: *Adjudicator, ply: usize, white_score: i32) ?Outcome {
        const sign: i32 = if (white_score > 0) 1 else -1;
        if (@abs(white_score) >= win_score) {
            if (sign == a.win_sign) a.win_plies += 1 else {
                a.win_sign = sign;
                a.win_plies = 1;
            }
            if (a.win_plies >= win_needed) return if (sign > 0) .white else .black;
        } else a.win_plies = 0;

        if (ply >= draw_after_ply and @abs(white_score) <= draw_score) {
            a.draw_plies += 1;
            if (a.draw_plies >= draw_needed) return .draw;
        } else a.draw_plies = 0;

        if (ply >= max_ply) return .draw;
        return null;
    }
};

/// Pick a random opening whose evaluation is roughly balanced: a book position
/// (plus up to one random move, for variety) when a book is given, otherwise
/// 8-9 random moves from the start position.
pub fn balancedOpening(rng: std.Random, s: *search.Searcher, max_abs: i32, book: ?[]const Position) Position {
    while (true) {
        var pos: Position = undefined;
        if (book) |positions| {
            pos = positions[rng.uintLessThan(usize, positions.len)];
            if (rng.boolean()) {
                var list = movegen.MoveList{};
                movegen.generate(&pos, &list, .all);
                if (list.len == 0) continue;
                pos = pos.makeMove(list.moves[rng.uintLessThan(usize, list.len)]);
            }
            var list = movegen.MoveList{};
            movegen.generate(&pos, &list, .all);
            if (list.len == 0) continue;
        } else {
            const plies = 8 + rng.uintLessThan(usize, 2);
            pos = randomOpening(rng, plies) orelse continue;
        }
        s.tt.clear();
        s.setPosition(&pos, &.{});
        const r = s.search(.{ .soft_nodes = 4000, .nodes = 40000 });
        if (@abs(r.score) <= max_abs) return pos;
    }
}

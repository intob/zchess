//! Live coaching for UCI play: while the engine thinks, judges the
//! opponent's (the user's) last move the way `review` does, and writes a
//! one-line comment: how much it cost in winning chances, what went wrong in
//! plain language, and the better move with its line.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const review = @import("review.zig");
const play = @import("play.zig");

const Position = position.Position;
const Move = position.Move;

/// Search effort per position (two per comment): a few tenths of a second.
pub const NODES = 300_000;

/// Moves of a line to show.
const LINE_LEN = 4;

/// Comment on `move`, played in `before`. `keys` are the positions of the
/// game up to and including `before` (for repetitions).
pub fn comment(s: *search.Searcher, before: *const Position, move: Move, keys: []const u64, w: *Io.Writer) !void {
    const after = before.makeMove(move);
    const eb = review.evalPosition(s, before, keys[0 .. keys.len -| 1], NODES);
    const ea = review.evalPosition(s, &after, keys, NODES);
    const g = review.grade(eb.score, ea.score);

    var sb: [16]u8 = undefined;
    var bsb: [16]u8 = undefined;
    const played = play.san(before, move, &sb);
    const best = play.san(before, eb.best, &bsb);
    try w.print("{d}{s} {s}", .{ before.fullmove, if (before.side == bb.WHITE) "." else "...", played });

    if (g.cls == .good) {
        if (move.eql(eb.best)) {
            try w.writeAll(": best move.");
        } else {
            try w.print(": good. {s} was also strong.", .{best});
        }
    } else {
        const positions = [2]Position{ before.*, after };
        const evals = [2]review.Eval{ eb, ea };
        const label = review.classifyKind(&positions, &evals, &.{move}, 0);
        var xb: [128]u8 = undefined;
        try w.print("{s} {s}: {s} (win chance {d:.0}% -> {d:.0}%). Better was {s}", .{
            switch (g.cls) {
                .inaccuracy => "?!",
                .mistake => "?",
                else => "??",
            },
            switch (g.cls) {
                .inaccuracy => "Inaccuracy",
                .mistake => "Mistake",
                else => "Blunder",
            },
            review.explain(label, best, &xb),
            review.winPct(eb.score),
            review.winPct(-ea.score),
            best,
        });
        if (eb.pv_len > 1) {
            try w.writeAll(" (");
            try writeLine(w, before.*, eb.pv[0..eb.pv_len]);
            try w.writeByte(')');
        }
        try w.writeByte('.');
        // What the opponent now threatens, for the bigger mistakes.
        if (g.cls != .inaccuracy and ea.pv_len > 0) {
            try w.writeAll(" The punishment: ");
            try writeLine(w, after, ea.pv[0..ea.pv_len]);
            try w.writeByte('.');
        }
    }
    try w.writeAll(" Eval: ");
    try writeScore(w, -ea.score);
}

/// The first moves of `pv` from `start`, in SAN.
fn writeLine(w: *Io.Writer, start: Position, pv: []const Move) !void {
    var p = start;
    for (pv[0..@min(pv.len, LINE_LEN)], 0..) |m, k| {
        var b: [16]u8 = undefined;
        if (k > 0) try w.writeByte(' ');
        try w.writeAll(play.san(&p, m, &b));
        p = p.makeMove(m);
    }
}

/// `score` from the user's point of view: pawns, or a mate count.
fn writeScore(w: *Io.Writer, score: i32) !void {
    if (@abs(score) >= search.MATE_BOUND) {
        const moves = @divTrunc(search.MATE - @as(i32, @intCast(@abs(score))) + 1, 2);
        return w.print("{s} in {d}", .{ if (score > 0) "you mate" else "you get mated", moves });
    }
    try w.print("{s}{d}.{d:0>2}", .{ if (score < 0) "-" else "+", @abs(score) / 100, @abs(score) % 100 });
}

/// Log header for a new game.
pub fn writeHeader(w: *Io.Writer, io: Io, user: bb.Color) !void {
    const ns = Io.Clock.real.now(io).toNanoseconds();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(ns, std.time.ns_per_s)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("\n=== zchess coach: new game {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC, you are {s} ===\n", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), if (user == bb.WHITE) "White" else "Black",
    });
}

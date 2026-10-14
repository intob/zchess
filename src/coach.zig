//! Live coaching for UCI play: while the engine thinks, judges the
//! opponent's (the user's) last move the way `review` does, and writes a
//! one-line comment: how much it cost in winning chances, what went wrong in
//! plain language, and the better move with its line. In the opening it also
//! names the opening, says whether the move is theory (from strong players'
//! games), gives an opening-principle tip for weak moves, and how the user
//! has done from here in their own games (see openings.zig).

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const review = @import("review.zig");
const play = @import("play.zig");
const movegen = @import("movegen.zig");
const openings = @import("openings.zig");

const Position = position.Position;
const Move = position.Move;

/// Search effort per position (two per comment): a few tenths of a second.
pub const NODES = 300_000;

/// Moves of a line to show.
const LINE_LEN = 4;

/// Games through a position for its moves to count as theory.
const MIN_THEORY = 20;
/// Share of those games (percent) below which a move is a rare sideline.
const MIN_BOOK_PCT = 2;
/// Principle tips only in the first moves.
const TIP_MOVES = 12;

/// Opening knowledge, and what the coach has already said this game.
pub const Context = struct {
    book: ?openings.Book = null,
    rep: ?*const openings.Repertoire = null,
    /// The opening name last announced (its index in the book).
    named: ?u32 = null,

    pub fn newGame(c: *Context) void {
        c.named = null;
    }
};

/// Comment on `move`, played in `before`. `keys` are the positions of the
/// game up to and including `before` (for repetitions).
pub fn comment(s: *search.Searcher, ctx: *Context, before: *const Position, move: Move, keys: []const u64, w: *Io.Writer) !void {
    const after = before.makeMove(move);
    const eb = review.evalPosition(s, before, keys[0 .. keys.len -| 1], NODES);
    const ea = review.evalPosition(s, &after, keys, NODES);
    const g = review.grade(eb.score, ea.score);

    var sb: [16]u8 = undefined;
    var bsb: [16]u8 = undefined;
    const played = play.san(before, move, &sb);
    const best = play.san(before, eb.best, &bsb);
    try w.print("{d}{s} {s}", .{ before.fullmove, if (before.side == bb.WHITE) "." else "...", played });

    var label: review.Label = .{};
    if (g.cls == .good) {
        if (move.eql(eb.best)) {
            try w.writeAll(": best move.");
        } else {
            try w.print(": good. {s} was also strong.", .{best});
        }
    } else {
        const positions = [2]Position{ before.*, after };
        const evals = [2]review.Eval{ eb, ea };
        label = review.classifyKind(&positions, &evals, &.{move}, 0);
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
    if (ctx.book) |*book| {
        try writeOpeningName(w, book, ctx, after.key, keys);
        try writeTheory(w, book, before, move);
    }
    // A principle only when the engine also dislikes the move, and nothing
    // more concrete (a hung piece, a missed capture) explains it.
    if (g.cls != .good and label.kind == .other) {
        if (tip(before, move)) |t| try w.print(" Tip: {s}", .{t});
    }
    if (ctx.rep) |r| {
        if (r.get(after.key)) |rec| if (rec.games >= 2) try w.print(" You've reached this position in {d} of your games: {d} won, {d} drawn, {d} lost.", .{
            rec.games, rec.wins, rec.draws, rec.losses,
        });
    }
    try w.writeAll(" Eval: ");
    try writeScore(w, -ea.score);
}

/// Search effort for each of the two searches of an opponent comment.
pub const THREAT_NODES = 150_000;

/// A threat counts when passing would cost the user this much (centipawns).
const THREAT_MARGIN = 150;

/// Comment on the opponent's `move`, played in `before`: opening name and
/// theory, what it captures or checks, and what it threatens (the best
/// move the opponent would have if the user passed). `keys` are the
/// positions of the game up to and including `before`.
pub fn opponent(s: *search.Searcher, ctx: *Context, before: *const Position, move: Move, keys: []const u64, w: *Io.Writer) !void {
    const after = before.makeMove(move);
    var sb: [16]u8 = undefined;
    try w.print("Opponent played {d}{s} {s}.", .{ before.fullmove, if (before.side == bb.WHITE) "." else "...", play.san(before, move, &sb) });
    if (ctx.book) |*book| {
        try writeOpeningName(w, book, ctx, after.key, keys);
        try writeTheory(w, book, before, move);
    }
    if (review.victimOf(before, move)) |v| try w.print(" It takes your {s}.", .{review.piece_names[v]});
    var replies = movegen.MoveList{};
    movegen.generate(&after, &replies, .all);
    if (replies.len == 0) return w.writeAll(if (after.inCheck()) " Checkmate." else " Stalemate.");

    // The user's view of the position, and the opponent's if the user passed.
    var with_after: [MAX_KEYS]u64 = undefined;
    const n = @min(keys.len, MAX_KEYS - 1);
    @memcpy(with_after[0..n], keys[keys.len - n ..]);
    with_after[n] = after.key;
    const ea = review.evalPosition(s, &after, keys, THREAT_NODES);
    if (after.inCheck()) {
        try w.writeAll(" Check!");
        if (ea.score <= -search.MATE_BOUND) try w.writeAll(" It leads to a forced mate.");
    } else {
        const null_pos = after.makeNull();
        const et = review.evalPosition(s, &null_pos, with_after[0 .. n + 1], THREAT_NODES);
        // et.score: the opponent's view if the user passed; -ea.score: their view now.
        if (et.score >= search.MATE_BOUND and -ea.score < search.MATE_BOUND) {
            try w.writeAll(" Threatens mate: ");
            try writeLine(w, null_pos, et.pv[0..et.pv_len]);
            try w.writeByte('.');
        } else if (et.best.data != 0 and et.score - (-ea.score) >= THREAT_MARGIN) {
            var tb: [16]u8 = undefined;
            const threat = play.san(&null_pos, et.best, &tb);
            if (review.victimOf(&null_pos, et.best)) |v| {
                try w.print(" Threatens {s}, winning your {s}.", .{ threat, review.piece_names[v] });
            } else {
                try w.print(" Threatens {s} (", .{threat});
                try writeLine(w, null_pos, et.pv[0..et.pv_len]);
                try w.writeAll(").");
            }
        } else {
            try w.writeAll(" No direct threat.");
        }
    }
    try w.writeAll(" Eval: ");
    try writeScore(w, ea.score);
}

/// Game history kept for an opponent comment's searches.
const MAX_KEYS = 512;

/// The opening's name when it has changed since the last one announced: the
/// latest named position of the game, so transpositions count.
fn writeOpeningName(w: *Io.Writer, book: *const openings.Book, ctx: *Context, after: u64, keys: []const u64) !void {
    const n = book.name(after) orelse blk: {
        var i = keys.len;
        while (i > 0) {
            i -= 1;
            if (book.name(keys[i])) |x| break :blk x;
        }
        return;
    };
    if (ctx.named == n.index) return;
    ctx.named = n.index;
    try w.print(" Opening: {s} ({s}).", .{ n.name, n.eco });
}

fn pct(n: u64, total: u64) u64 {
    return (n * 100 + total / 2) / total;
}

/// Whether `move` is theory: how often 2000+ players chose it here, or what
/// they play instead when it leaves the book.
fn writeTheory(w: *Io.Writer, book: *const openings.Book, before: *const Position, move: Move) !void {
    const ms = book.moves(before.key);
    const total = ms.total();
    if (total < MIN_THEORY) return;
    var rank: ?usize = null;
    var mine: u64 = 0;
    for (0..ms.len()) |i| {
        const e = ms.get(i);
        if (e.move.eql(move)) {
            rank = i;
            mine = e.games();
            break;
        }
    }
    if (rank != null and pct(mine, total) >= MIN_BOOK_PCT) {
        return w.print(" {s}: played in {d}% of {d} games between 2000+ players.", .{
            if (rank.? == 0) "Main line" else "Book move", pct(mine, total), total,
        });
    }
    if (rank != null) {
        const p = pct(mine, total);
        if (p == 0) {
            try w.print(" A rare sideline (under 1% of {d} games between 2000+ players); they mostly play ", .{total});
        } else {
            try w.print(" A rare sideline ({d}% of {d} games between 2000+ players); they mostly play ", .{ p, total });
        }
    } else {
        try w.writeAll(" This leaves opening theory; 2000+ players play ");
    }
    for (0..@min(ms.len(), 3)) |i| {
        const e = ms.get(i);
        if (i > 0 and pct(e.games(), total) < 5) break;
        var b: [16]u8 = undefined;
        if (i > 0) try w.writeAll(", ");
        try w.print("{s} ({d}%)", .{ play.san(before, e.move, &b), pct(e.games(), total) });
    }
    try w.writeAll(" here.");
}

/// An opening principle the move goes against, if any.
fn tip(before: *const Position, move: Move) ?[]const u8 {
    if (before.fullmove > TIP_MOVES) return null;
    const us = before.side;
    const from = move.from();
    const pt = bb.pieceType(before.board[from]);
    // b, c, f and g files of the back rank: where knights and bishops start.
    const home: u64 = if (us == bb.WHITE) 0x66 else 0x66 << 56;
    const minors = before.piecesOf(us, bb.KNIGHT) | before.piecesOf(us, bb.BISHOP);
    const undeveloped = bb.popcount(minors & home);
    const king_home: bb.Square = if (us == bb.WHITE) 4 else 60;
    const rights: u4 = if (us == bb.WHITE) position.WK | position.WQ else position.BK | position.BQ;
    const can_castle = before.castling & rights != 0;

    if (pt == bb.KING and !move.isCastle() and can_castle)
        return "moving your king gives up castling, which would have kept it safe.";
    if (move.isCapture()) return null;
    if (pt == bb.QUEEN and undeveloped >= 2)
        return "bringing the queen out early lets your opponent develop with tempo by attacking it; get your knights and bishops out first.";
    if ((pt == bb.KNIGHT or pt == bb.BISHOP) and bb.bit(from) & home == 0 and undeveloped >= 2 and
        !before.attackedBy(from, us ^ 1, before.occupied()))
        return "moving the same piece twice in the opening costs time; develop another piece instead.";
    if (pt == bb.PAWN and undeveloped >= 2 and (bb.fileOf(from) <= 1 or bb.fileOf(from) >= 6))
        return "pawn moves on the wing don't help your development; fight for the centre and get your pieces out.";
    if (undeveloped >= 3 and before.fullmove >= 6 and bb.bit(from) & minors & home == 0)
        return "you still have most of your pieces at home; developing them is usually worth more than this.";
    if (before.fullmove >= 8 and pt != bb.KING and can_castle and before.kingSq(us) == king_home)
        return "your king is still in the centre; castling soon keeps it safe and connects your rooks.";
    return null;
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

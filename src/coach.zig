//! Live coaching for UCI play: while the engine thinks, judges the
//! opponent's (the user's) last move the way `review` does, and writes a
//! one-line comment: how much it cost in winning chances, what went wrong in
//! plain language, and the better move with its line. In the opening it also
//! names the opening, says whether the move is theory (from strong players'
//! games), gives an opening-principle tip for weak moves, and how the user
//! has done from here in their own games (see openings.zig).
//!
//! With a focus file (written by scripts/ec-sync.py from the review of the
//! user's games) the first comment of each game names the user's biggest
//! leak and the habit that fixes it, and a mistake of that same kind says so.
//! Hints (optional) point out the user's loose pieces after each engine move.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const review = @import("review.zig");
const play = @import("play.zig");
const movegen = @import("movegen.zig");
const openings = @import("openings.zig");
const tactics = @import("tactics.zig");

const Position = position.Position;
const Move = position.Move;

/// Search effort per position (two per comment): a few tenths of a second.
pub const NODES = 300_000;

/// Moves of a line to show.
const LINE_LEN = 4;

/// Games through a position for its moves to count as theory.
pub const MIN_THEORY = 20;
/// Share of those games (percent) below which a move is a rare sideline.
pub const MIN_BOOK_PCT = 2;
/// Principle tips only in the first moves.
const TIP_MOVES = 12;

/// Opening knowledge, and what the coach has already said this game.
pub const Context = struct {
    book: ?openings.Book = null,
    rep: ?*const openings.Repertoire = null,
    /// The opening name last announced (its index in the book).
    named: ?u32 = null,
    /// The user's biggest leak, from the focus file.
    focus: Focus = .{},
    focus_said: bool = false,
    /// Point out the user's loose pieces after each engine move.
    hints: bool = false,

    pub fn newGame(c: *Context) void {
        c.named = null;
        c.focus_said = false;
    }
};

/// The focus file: `lesson=`, `text=` and `habit=` lines (see
/// scripts/leaks.py), kept in the folder of the user's games.
pub const Focus = struct {
    buf: [1024]u8 = undefined,
    lesson_: [2]usize = .{ 0, 0 },
    text_: [2]usize = .{ 0, 0 },
    habit_: [2]usize = .{ 0, 0 },

    pub const FILE = ".focus";

    pub fn lesson(f: *const Focus) []const u8 {
        return f.buf[f.lesson_[0]..][0..f.lesson_[1]];
    }
    pub fn text(f: *const Focus) []const u8 {
        return f.buf[f.text_[0]..][0..f.text_[1]];
    }
    pub fn habit(f: *const Focus) []const u8 {
        return f.buf[f.habit_[0]..][0..f.habit_[1]];
    }

    pub fn parse(bytes: []const u8) Focus {
        var f = Focus{};
        const n = @min(bytes.len, f.buf.len);
        @memcpy(f.buf[0..n], bytes[0..n]);
        var start: usize = 0;
        var it = std.mem.splitScalar(u8, f.buf[0..n], '\n');
        while (it.next()) |raw| {
            defer start += raw.len + 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const slot = if (std.mem.eql(u8, line[0..eq], "lesson")) &f.lesson_ else if (std.mem.eql(u8, line[0..eq], "text")) &f.text_ else if (std.mem.eql(u8, line[0..eq], "habit")) &f.habit_ else continue;
            slot.* = .{ start + eq + 1, line.len - eq - 1 };
        }
        return f;
    }

    /// Reads `<dir>/.focus`; empty when there's none (or `dir` is a file).
    pub fn load(io: Io, dir: []const u8) Focus {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, FILE }) catch return .{};
        var buf: [1024]u8 = undefined;
        const bytes = Io.Dir.cwd().readFile(io, path, &buf) catch return .{};
        return parse(bytes);
    }
};

/// The focus for this game, once, at the start of the first comment.
fn writeFocus(ctx: *Context, w: *Io.Writer) !void {
    if (ctx.focus_said) return;
    ctx.focus_said = true;
    if (ctx.focus.text().len == 0) return;
    try w.print("Focus this game: {s} {s} | ", .{ ctx.focus.text(), ctx.focus.habit() });
}

/// Comment on `move`, played in `before`. `keys` are the positions of the
/// game up to and including `before` (for repetitions).
pub fn comment(s: *search.Searcher, ctx: *Context, before: *const Position, move: Move, keys: []const u64, w: *Io.Writer) !void {
    const after = before.makeMove(move);
    const eb = review.evalPosition(s, before, keys[0 .. keys.len -| 1], NODES);
    const ea = review.evalPosition(s, &after, keys, NODES);
    const j = review.judge(s, before, move, eb, ea, keys, NODES);
    const g = j.g;

    var sb: [16]u8 = undefined;
    var bsb: [16]u8 = undefined;
    var rsb: [16]u8 = undefined;
    const played = play.san(before, move, &sb);
    const best = play.san(before, eb.best, &bsb);
    const reply = if (ea.best.data != 0) play.san(&after, ea.best, &rsb) else "";
    try writeFocus(ctx, w);
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
        var xb: [192]u8 = undefined;
        try w.print("{s} {s}: {s} (", .{
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
            review.explain(label, best, reply, &xb),
        });
        // Far ahead or behind the winning chances barely move; show the eval.
        if (g.by_eval) {
            try w.writeAll("eval ");
            try writeScore(w, j.before);
            try w.writeAll(" -> ");
            try writeScore(w, -ea.score);
        } else {
            try w.print("win chance {d:.0}% -> {d:.0}%", .{ review.winPct(j.before), review.winPct(-ea.score) });
        }
        try w.print("). Better was {s}", .{best});
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
    // more concrete (a hung piece, a tactic) explains it.
    if (g.cls != .good and label.lesson() == .positional) {
        if (tip(before, move)) |t| try w.print(" Tip: {s}", .{t});
    }
    // The user's biggest leak, again.
    if (g.cls == .mistake or g.cls == .blunder) {
        if (std.mem.eql(u8, ctx.focus.lesson(), @tagName(label.lesson()))) try w.print(" That's your #1 leak again. {s}", .{ctx.focus.habit()});
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

/// The user's move before the opponent's, played in `before`.
pub const Prev = struct { before: *const Position, move: Move };

/// For saying whether a recapture is an even trade.
const trade_value = [6]u32{ 1, 3, 3, 5, 9, 0 };

/// Comment on the opponent's `move`, played in `before`: opening name and
/// theory, what it captures (a trade, when it takes back on the square of
/// the user's capture `prev`) or checks, and what it threatens (the best
/// move the opponent would have if the user passed). `keys` are the
/// positions of the game up to and including `before`.
pub fn opponent(s: *search.Searcher, ctx: *Context, before: *const Position, move: Move, prev: ?Prev, keys: []const u64, w: *Io.Writer) !void {
    const after = before.makeMove(move);
    var sb: [16]u8 = undefined;
    try writeFocus(ctx, w);
    try w.print("Opponent played {d}{s} {s}.", .{ before.fullmove, if (before.side == bb.WHITE) "." else "...", play.san(before, move, &sb) });
    if (ctx.book) |*book| {
        try writeOpeningName(w, book, ctx, after.key, keys);
        try writeTheory(w, book, before, move);
    }
    if (review.victimOf(before, move)) |v| {
        const names = review.piece_names;
        const took = if (prev) |p| (if (p.move.to() == move.to()) review.victimOf(p.before, p.move) else null) else null;
        if (took) |t| {
            if (t == v) {
                try w.print(" It takes back: {s}s traded.", .{names[v]});
            } else if (trade_value[t] == trade_value[v]) {
                try w.print(" It takes back: your {s} for its {s}, an even trade.", .{ names[v], names[t] });
            } else if (trade_value[t] > trade_value[v]) {
                try w.print(" It takes your {s} back, but you took its {s}: you win the trade.", .{ names[v], names[t] });
            } else {
                try w.print(" It takes your {s} back, for its {s}: you lose the trade.", .{ names[v], names[t] });
            }
        } else try w.print(" It takes your {s}.", .{names[v]});
    }
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
    if (ctx.hints) _ = try hints(&after, w);
    try w.writeAll(" Eval: ");
    try writeScore(w, ea.score);
}

/// Hints alone (no searches), for the engine's `move` played in `before`:
/// the user's loose pieces afterwards. False when there are none.
pub fn hintsOnly(ctx: *Context, before: *const Position, move: Move, w: *Io.Writer) !bool {
    const after = before.makeMove(move);
    if (tactics.loosePieces(&after, after.side) == 0) return false;
    var sb: [16]u8 = undefined;
    try writeFocus(ctx, w);
    try w.print("After {d}{s} {s}:", .{ before.fullmove, if (before.side == bb.WHITE) "." else "...", play.san(before, move, &sb) });
    return hints(&after, w);
}

/// The side to move's loose pieces in `p` (attacked, and undefended or
/// attacked by something cheaper), most valuable first. False when none.
pub fn hints(p: *const Position, w: *Io.Writer) !bool {
    const loose = tactics.loosePieces(p, p.side);
    if (loose == 0) return false;
    try w.writeAll(" Watch:");
    var first = true;
    var pt: usize = bb.QUEEN + 1;
    while (pt > bb.KNIGHT) {
        pt -= 1;
        var l = loose & p.pieces[pt];
        while (l != 0) {
            const sq = bb.popLsb(&l);
            const attackers = p.attackersTo(sq, p.occupied()) & p.colors[p.side ^ 1];
            const name = bb.squareName(sq);
            try w.print("{s} your {s} on {s} is ", .{ if (first) "" else ";", review.piece_names[pt], &name });
            if (tactics.isDefended(p, sq)) {
                try w.print("attacked by a {s}", .{review.piece_names[tactics.cheapestType(p, attackers)]});
            } else {
                try w.writeAll("attacked and undefended");
            }
            first = false;
        }
    }
    try w.writeByte('.');
    return true;
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

/// Log header for a new game; `elo` is the strength zchess plays at (null: full).
pub fn writeHeader(w: *Io.Writer, io: Io, user: bb.Color, elo: ?u32) !void {
    const ns = Io.Clock.real.now(io).toNanoseconds();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(ns, std.time.ns_per_s)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("\n=== zchess coach: new game {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC, you are {s}, zchess plays at ", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), if (user == bb.WHITE) "White" else "Black",
    });
    if (elo) |e| try w.print("Elo {d} ===\n", .{e}) else try w.writeAll("full strength ===\n");
}

test "focus file" {
    const f = Focus.parse("lesson=hung_piece\ntext=You hung a piece in 9 of your last 20 games.\r\nhabit=Check what the last move attacks.\n");
    try std.testing.expectEqualStrings("hung_piece", f.lesson());
    try std.testing.expectEqualStrings("You hung a piece in 9 of your last 20 games.", f.text());
    try std.testing.expectEqualStrings("Check what the last move attacks.", f.habit());
    const empty = Focus.parse("");
    try std.testing.expectEqualStrings("", empty.text());
}

test "hints name loose pieces" {
    const atk = @import("attacks.zig");
    atk.init();
    const p = try Position.fromFen("4k3/8/2n5/1b1P4/8/8/8/R3K3 b - - 0 1");
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.testing.expect(try hints(&p, &w));
    try std.testing.expectEqualStrings(" Watch: your knight on c6 is attacked by a pawn.", w.buffered());
}

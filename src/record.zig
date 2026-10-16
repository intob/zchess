//! Records the games zchess plays as a UCI engine (with Coach on): one PGN
//! per game in the GameRecord folder, rewritten after each engine move, with
//! the coach's comments. GUIs such as En Croissant don't save played games,
//! and don't tell the engine when the user resigns, flags or mates, so the
//! file is kept current and the result is filled in only when the board
//! decides it (the engine mates, stalemate, a draw by rule); otherwise `*`.
//! scripts/ec-sync.py reviews the finished games and adds them to an En
//! Croissant database.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const play = @import("play.zig");
const game = @import("game.zig");

const Position = position.Position;
const Move = position.Move;

/// A move list this short (the engine moves first, or replies to the first
/// move) that drops recorded moves starts a new game; any other takeback,
/// however deep, is the same game. En Croissant starts a new engine
/// process for each game and never sends `ucinewgame`; other GUIs do.
const NEW_GAME_PLIES = 1;

pub const Record = struct {
    active: bool = false,
    start: Position = undefined,
    moves: std.ArrayList(Move) = .empty,
    /// One per move ("" for none), owned.
    comments: std.ArrayList([]u8) = .empty,
    /// When the game started (epoch seconds, UTC): the file name and Date.
    started: i64 = 0,
    engine: bb.Color = bb.WHITE,
    /// Clock at the start (ms, the larger of the two at the first `go`), and
    /// the increment; base < 0 when the game has no clock.
    base_ms: i64 = -1,
    inc_ms: i64 = 0,

    pub fn deinit(r: *Record, gpa: std.mem.Allocator) void {
        r.truncate(gpa, 0);
        r.moves.deinit(gpa);
        r.comments.deinit(gpa);
    }

    fn truncate(r: *Record, gpa: std.mem.Allocator, n: usize) void {
        for (r.comments.items[n..]) |c| gpa.free(c);
        r.comments.shrinkRetainingCapacity(n);
        r.moves.shrinkRetainingCapacity(n);
    }

    /// Brings the record up to the game the GUI sent (`start` and `moves`,
    /// the engine to move): the same game after takebacks (and other moves
    /// played instead), a new one from another start position or when the
    /// GUI sends the start of a game (see NEW_GAME_PLIES); `ucinewgame`
    /// clears `active`. True when a new game starts.
    pub fn sync(r: *Record, gpa: std.mem.Allocator, start: *const Position, moves: []const Move, now: i64) !bool {
        const common = blk: {
            if (!r.active or r.start.key != start.key) break :blk null;
            const n = @min(r.moves.items.len, moves.len);
            var c: usize = 0;
            while (c < n and r.moves.items[c].eql(moves[c])) c += 1;
            if (moves.len <= NEW_GAME_PLIES and r.moves.items.len > c) break :blk null;
            break :blk c;
        };
        const fresh = common == null;
        if (fresh) {
            r.truncate(gpa, 0);
            r.active = true;
            r.start = start.*;
            r.started = now;
            r.base_ms = -1;
            r.inc_ms = 0;
            var p = start.*;
            for (moves) |m| p = p.makeMove(m);
            r.engine = p.side;
        }
        r.truncate(gpa, common orelse 0);
        for (moves[r.moves.items.len..]) |m| try r.push(gpa, m, "");
        return fresh;
    }

    /// Appends a move with its comment (copied).
    pub fn push(r: *Record, gpa: std.mem.Allocator, m: Move, comment: []const u8) !void {
        const c = try gpa.dupe(u8, comment);
        errdefer gpa.free(c);
        try r.moves.append(gpa, m);
        try r.comments.append(gpa, c);
    }

    /// Sets the last move's comment (copied).
    pub fn commentLast(r: *Record, gpa: std.mem.Allocator, comment: []const u8) !void {
        if (r.comments.items.len == 0) return;
        const c = try gpa.dupe(u8, comment);
        const last = &r.comments.items[r.comments.items.len - 1];
        gpa.free(last.*);
        last.* = c;
    }

    /// File name (no extension) and Link of the game: its start, UTC.
    pub fn stem(r: *const Record, buf: *[32]u8) []const u8 {
        const t = utc(r.started);
        return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ t.year, t.month, t.day, t.hour, t.min, t.sec }) catch unreachable;
    }

    /// The result the board decides after the last move, else "*".
    pub fn result(r: *const Record, gpa: std.mem.Allocator) []const u8 {
        var keys: std.ArrayList(u64) = .empty;
        defer keys.deinit(gpa);
        var p = r.start;
        for (r.moves.items) |m| {
            keys.append(gpa, p.key) catch return "*";
            p = p.makeMove(m);
        }
        return switch (game.terminal(&p, keys.items) orelse return "*") {
            .white => "1-0",
            .black => "0-1",
            .draw => "1/2-1/2",
        };
    }

    pub const Players = struct {
        user: []const u8,
        engine: []const u8,
        engine_elo: ?u32 = null,
        /// Written as the Link header (where the game lives).
        link: []const u8 = "",
    };

    pub fn write(r: *const Record, gpa: std.mem.Allocator, w: *Io.Writer, players: Players) !void {
        const t = utc(r.started);
        const res = r.result(gpa);
        const white, const black = if (r.engine == bb.WHITE) .{ players.engine, players.user } else .{ players.user, players.engine };
        try w.print("[Event \"Casual game vs zchess\"]\n[Site \"zchess\"]\n[Date \"{d}.{d:0>2}.{d:0>2}\"]\n[Round \"-\"]\n", .{ t.year, t.month, t.day });
        try w.print("[White \"{s}\"]\n[Black \"{s}\"]\n[Result \"{s}\"]\n", .{ white, black, res });
        if (players.engine_elo) |e| try w.print("[{s}Elo \"{d}\"]\n", .{ if (r.engine == bb.WHITE) "White" else "Black", e });
        try w.print("[UTCDate \"{d}.{d:0>2}.{d:0>2}\"]\n[UTCTime \"{d:0>2}:{d:0>2}:{d:0>2}\"]\n", .{ t.year, t.month, t.day, t.hour, t.min, t.sec });
        if (r.base_ms >= 0) {
            try w.print("[TimeControl \"{d}+{d}\"]\n", .{ @divTrunc(r.base_ms + 500, 1000), @divTrunc(r.inc_ms + 500, 1000) });
        } else try w.writeAll("[TimeControl \"-\"]\n");
        if (r.start.key != Position.startpos().key) {
            var fb: [128]u8 = undefined;
            try w.print("[SetUp \"1\"]\n[FEN \"{s}\"]\n", .{r.start.toFen(&fb)});
        }
        if (players.link.len > 0) try w.print("[Link \"{s}\"]\n", .{players.link});
        try w.writeByte('\n');

        var p = r.start;
        var need_number = true;
        for (r.moves.items, r.comments.items) |m, c| {
            if (p.side == bb.WHITE) try w.print("{d}. ", .{p.fullmove}) else if (need_number) try w.print("{d}... ", .{p.fullmove});
            need_number = false;
            var sb: [16]u8 = undefined;
            try w.writeAll(play.san(&p, m, &sb));
            if (c.len > 0) {
                try w.writeAll(" {");
                // No braces or line breaks inside a PGN comment.
                for (c) |ch| try w.writeByte(switch (ch) {
                    '{' => '(',
                    '}' => ')',
                    '\n', '\r' => ' ',
                    else => ch,
                });
                try w.writeByte('}');
                need_number = true;
            }
            try w.writeByte(' ');
            p = p.makeMove(m);
        }
        try w.print("{s}\n", .{res});
    }

    /// Writes the game to `<dir>/<stem>.pgn` (via a temporary file, so a
    /// reader never sees half a game).
    pub fn save(r: *const Record, gpa: std.mem.Allocator, io: Io, dir: []const u8, players: Players) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, dir);
        var sb: [32]u8 = undefined;
        const name = r.stem(&sb);
        var pb: [1024]u8 = undefined;
        var tb: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}.pgn", .{ dir, name });
        const tmp = try std.fmt.bufPrint(&tb, "{s}/.{s}.pgn.tmp", .{ dir, name });
        var lb: [1100]u8 = undefined;
        var pl = players;
        if (pl.link.len == 0) pl.link = try std.fmt.bufPrint(&lb, "file://{s}", .{path});
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try r.write(gpa, &aw.writer, pl);
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
        try cwd.rename(tmp, cwd, path, io);
    }
};

const Utc = struct { year: u16, month: u8, day: u8, hour: u8, min: u8, sec: u8 };

fn utc(secs: i64) Utc {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{ .year = yd.year, .month = md.month.numeric(), .day = md.day_index + 1, .hour = ds.getHoursIntoDay(), .min = ds.getMinutesIntoHour(), .sec = ds.getSecondsIntoMinute() };
}

test "record: takebacks, new games, comments, result" {
    const atk = @import("attacks.zig");
    atk.init();
    const movegen = @import("movegen.zig");
    const gpa = std.testing.allocator;
    var r = Record{};
    defer r.deinit(gpa);
    const start = Position.startpos();
    var moves: [8]Move = undefined;
    var p = start;
    // Fool's mate: 1. f3 e5 2. g4 Qh4#
    for ([_][]const u8{ "f2f3", "e7e5", "g2g4", "d8h4" }, 0..) |u, i| {
        moves[i] = movegen.parseUci(&p, u).?;
        p = p.makeMove(moves[i]);
    }
    // The engine is Black: the GUI sends 1. f3 and asks for a move.
    try std.testing.expect(try r.sync(gpa, &start, moves[0..1], 1_760_633_519));
    try std.testing.expectEqual(bb.BLACK, r.engine);
    try r.push(gpa, moves[1], "Opponent played 1... e5.");
    try std.testing.expect(!try r.sync(gpa, &start, moves[0..3], 1_760_633_530));
    try r.commentLast(gpa, "2. g4?? Blunder: allows mate in one.");
    try r.push(gpa, moves[3], "");
    try std.testing.expectEqualStrings("0-1", r.result(gpa));

    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.write(gpa, &w, .{ .user = "fingjoey", .engine = "zchess", .engine_elo = 1400 });
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "[White \"fingjoey\"]\n[Black \"zchess\"]\n[Result \"0-1\"]\n[BlackElo \"1400\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[UTCDate \"2025.10.16\"]\n[UTCTime \"16:51:59\"]") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n1. f3 e5 {Opponent played 1... e5.} 2. g4 {2. g4?? Blunder: allows mate in one.} 2... Qh4# 0-1\n"));
    var sb: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2025-10-16T165159Z", r.stem(&sb));

    // A takeback of one move keeps the game (and drops that move's comment)...
    try std.testing.expect(!try r.sync(gpa, &start, moves[0..3], 1_760_633_540));
    try std.testing.expectEqual(3, r.moves.items.len);
    // ...and so does taking back both sides' moves and playing another:
    // 1. f3 e5 2. g4 -> 1. f3 e5 2. h3.
    try r.push(gpa, moves[3], "");
    var other = moves;
    var q = start;
    for (moves[0..2]) |m| q = q.makeMove(m);
    other[2] = movegen.parseUci(&q, "h2h3").?;
    try std.testing.expect(!try r.sync(gpa, &start, other[0..3], 1_760_633_545));
    try std.testing.expectEqual(3, r.moves.items.len);
    try std.testing.expect(r.moves.items[2].eql(other[2]));
    try std.testing.expectEqualStrings("", r.comments.items[2]);
    try std.testing.expectEqualStrings("Opponent played 1... e5.", r.comments.items[1]);
    try std.testing.expectEqual(1_760_633_519, r.started);
    // ...or several moves back at once (no engine turn in between)...
    try std.testing.expect(!try r.sync(gpa, &start, other[0..2], 1_760_633_550));
    try std.testing.expectEqual(2, r.moves.items.len);
    // ...but the start of a game (the engine to make the first move) is a new game.
    try std.testing.expect(try r.sync(gpa, &start, moves[0..0], 1_760_633_600));
    try std.testing.expectEqual(0, r.moves.items.len);
    try std.testing.expectEqual(bb.WHITE, r.engine);
    try std.testing.expectEqualStrings("*", r.result(gpa));
}

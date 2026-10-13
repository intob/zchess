//! Opening knowledge for the coach. `zchess openings` builds one file, which
//! `zig build` embeds (-Dopenings, default data/openings.bin if present):
//!   - named openings: Lichess's chess-openings list (CC0), stored by position
//!     so that transpositions are named too;
//!   - a move tree of strong players' games: for each position of the first
//!     plies, the moves played there and how they scored.
//! The user's own record (`Repertoire`) is read at run time from their PGNs.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const play = @import("play.zig");
const pgn = @import("pgn.zig");
const cli = @import("cli.zig");
const build_options = @import("build_options");
const Output = @import("output.zig").Output;

const Position = position.Position;
const Move = position.Move;

const help =
    \\usage: zchess openings --out <openings.bin> [options] <games.pgn[.zst]>...
    \\
    \\  --names <files>    Lichess chess-openings TSVs (eco, name, pgn), comma-separated
    \\  --min-elo <n>      both players rated at least this (default 2000; 0 = any)
    \\  --plies <n>        depth of the move tree (default 30)
    \\  --min-games <n>    keep moves played in at least this many games (default 3)
    \\
;

// File layout, little endian: header, names (sorted by key), edges (sorted
// by key, most played first), name strings.
const MAGIC = "ZCOP";
const VERSION: u32 = 1;
const HEADER_SIZE = 32; // magic, version, n_names, n_edges, strings_len, plies, startpos key
const NAME_SIZE = 16; // key u64, eco [3]u8, name length u8, name offset u32
const EDGE_SIZE = 24; // key u64, move u16, pad u16, white wins u32, draws u32, black wins u32

pub const embedded: []const u8 = if (build_options.has_openings) @embedFile("openings") else "";

pub const Name = struct { eco: []const u8, name: []const u8, index: u32 };

pub const Edge = struct {
    move: Move,
    white: u32,
    draws: u32,
    black: u32,

    pub fn games(e: Edge) u32 {
        return e.white + e.draws + e.black;
    }
};

pub const Book = struct {
    bytes: []const u8,
    n_names: usize,
    n_edges: usize,
    names_off: usize,
    edges_off: usize,
    strings_off: usize,

    /// Null if `bytes` isn't a book for this build's position keys.
    pub fn parse(bytes: []const u8) ?Book {
        if (bytes.len < HEADER_SIZE or !std.mem.eql(u8, bytes[0..4], MAGIC)) return null;
        if (rd(u32, bytes, 4) != VERSION or rd(u64, bytes, 24) != Position.startpos().key) return null;
        const n_names = rd(u32, bytes, 8);
        const n_edges = rd(u32, bytes, 12);
        const names_off = HEADER_SIZE;
        const edges_off = names_off + n_names * NAME_SIZE;
        const strings_off = edges_off + n_edges * EDGE_SIZE;
        if (strings_off + rd(u32, bytes, 16) != bytes.len) return null;
        return .{ .bytes = bytes, .n_names = n_names, .n_edges = n_edges, .names_off = names_off, .edges_off = edges_off, .strings_off = strings_off };
    }

    pub fn embeddedBook() ?Book {
        return parse(embedded);
    }

    fn nameKey(b: *const Book, i: usize) u64 {
        return rd(u64, b.bytes, b.names_off + i * NAME_SIZE);
    }

    fn edgeKey(b: *const Book, i: usize) u64 {
        return rd(u64, b.bytes, b.edges_off + i * EDGE_SIZE);
    }

    pub fn name(b: *const Book, key: u64) ?Name {
        const i = lowerBound(b, b.n_names, key, nameKey);
        if (i == b.n_names or b.nameKey(i) != key) return null;
        const off = b.names_off + i * NAME_SIZE;
        const s = b.strings_off + rd(u32, b.bytes, off + 12);
        return .{ .eco = b.bytes[off + 8 ..][0..3], .name = b.bytes[s..][0..b.bytes[off + 11]], .index = @intCast(i) };
    }

    /// Moves played from the position with `key`, most played first.
    pub fn moves(b: *const Book, key: u64) Moves {
        const lo = lowerBound(b, b.n_edges, key, edgeKey);
        var hi = lo;
        while (hi < b.n_edges and b.edgeKey(hi) == key) hi += 1;
        return .{ .book = b, .lo = lo, .hi = hi };
    }

    pub const Moves = struct {
        book: *const Book,
        lo: usize,
        hi: usize,

        pub fn len(m: Moves) usize {
            return m.hi - m.lo;
        }

        pub fn get(m: Moves, i: usize) Edge {
            const off = m.book.edges_off + (m.lo + i) * EDGE_SIZE;
            const bytes = m.book.bytes;
            return .{ .move = .{ .data = rd(u16, bytes, off + 8) }, .white = rd(u32, bytes, off + 12), .draws = rd(u32, bytes, off + 16), .black = rd(u32, bytes, off + 20) };
        }

        pub fn total(m: Moves) u64 {
            var n: u64 = 0;
            for (0..m.len()) |i| n += m.get(i).games();
            return n;
        }
    };
};

fn rd(comptime T: type, bytes: []const u8, off: usize) T {
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little);
}

fn lowerBound(b: *const Book, n: usize, key: u64, comptime keyAt: fn (*const Book, usize) u64) usize {
    var lo: usize = 0;
    var hi = n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keyAt(b, mid) < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

// ---------------------------------------------------------------------------
// Building the file

const EdgeKey = struct { key: u64, move: u16 };
const Counts = struct { white: u32 = 0, draws: u32 = 0, black: u32 = 0 };
const NameRec = struct { key: u64, eco: [3]u8, len: u8, off: u32 };
const EdgeRec = struct { key: EdgeKey, counts: Counts };

const Builder = struct {
    gpa: std.mem.Allocator,
    min_elo: u32,
    plies: usize,
    edges: std.AutoHashMap(EdgeKey, Counts),
    games: u64 = 0,
    used: u64 = 0,

    fn elo(g: *const pgn.Game, key: []const u8) u32 {
        return std.fmt.parseInt(u32, g.header(key) orelse "0", 10) catch 0;
    }

    fn onGame(b: *Builder, g: *const pgn.Game) !void {
        b.games += 1;
        if (!g.isStandard()) return;
        if (b.min_elo > 0 and (elo(g, "WhiteElo") < b.min_elo or elo(g, "BlackElo") < b.min_elo)) return;
        const res = g.header("Result") orelse return;
        const outcome: u2 = if (std.mem.eql(u8, res, "1-0")) 0 else if (std.mem.eql(u8, res, "1/2-1/2")) 1 else if (std.mem.eql(u8, res, "0-1")) 2 else return;
        var pos = Position.startpos();
        var it = pgn.SanIterator.init(g.movetext);
        for (0..b.plies) |_| {
            const tok = it.next() orelse break;
            const m = play.parseMove(&pos, tok) orelse break;
            const gop = try b.edges.getOrPut(.{ .key = pos.key, .move = m.data });
            if (!gop.found_existing) gop.value_ptr.* = .{};
            switch (outcome) {
                0 => gop.value_ptr.white += 1,
                1 => gop.value_ptr.draws += 1,
                else => gop.value_ptr.black += 1,
            }
            pos = pos.makeMove(m);
        }
        b.used += 1;
    }

    fn readAll(b: *Builder, r: *Io.Reader) !void {
        try pgn.readGames(b.gpa, r, b, onGame);
    }
};

/// Position reached by a PGN move list from the start, or null if a move doesn't parse.
fn replay(movetext: []const u8) ?Position {
    var pos = Position.startpos();
    var it = pgn.SanIterator.init(movetext);
    while (it.next()) |tok| pos = pos.makeMove(play.parseMove(&pos, tok) orelse return null);
    return pos;
}

fn addNames(gpa: std.mem.Allocator, io: Io, path: []const u8, names: *std.ArrayList(NameRec), strings: *std.ArrayList(u8)) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const eco = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const moves = fields.next() orelse continue;
        if (eco.len != 3 or std.mem.eql(u8, eco, "eco")) continue;
        const pos = replay(moves) orelse continue;
        const len: u8 = @intCast(@min(name.len, 255));
        try names.append(gpa, .{ .key = pos.key, .eco = eco[0..3].*, .len = len, .off = @intCast(strings.items.len) });
        try strings.appendSlice(gpa, name[0..len]);
    }
}

fn nameLess(_: void, a: NameRec, b: NameRec) bool {
    return a.key < b.key;
}

fn edgeLess(_: void, a: EdgeRec, b: EdgeRec) bool {
    if (a.key.key != b.key.key) return a.key.key < b.key.key;
    const ga = a.counts.white + a.counts.draws + a.counts.black;
    const gb = b.counts.white + b.counts.draws + b.counts.black;
    return ga > gb;
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var out_path: []const u8 = "";
    var names_arg: []const u8 = "";
    var min_elo: u32 = 2000;
    var plies: usize = 30;
    var min_games: u32 = 3;
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    while (p.next()) |a| {
        if (p.flag(a, "--out")) |v| out_path = v
        else if (p.flag(a, "--names")) |v| names_arg = v
        else if (p.int(u32, a, "--min-elo")) |v| min_elo = v
        else if (p.int(usize, a, "--plies")) |v| plies = @max(v, 1)
        else if (p.int(u32, a, "--min-games")) |v| min_games = @max(v, 1)
        else if (a[0] != '-') try inputs.append(gpa, a)
        else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (out_path.len == 0) {
        out.print("{s}", .{help});
        return;
    }
    const t0 = Io.Clock.awake.now(io);

    // Names, one per position (the first listed wins).
    var names: std.ArrayList(NameRec) = .empty;
    defer names.deinit(gpa);
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(gpa);
    var nit = std.mem.tokenizeScalar(u8, names_arg, ',');
    while (nit.next()) |path| try addNames(gpa, io, path, &names, &strings);
    std.mem.sort(NameRec, names.items, {}, nameLess);
    var n_names: usize = 0;
    for (names.items) |n| {
        if (n_names > 0 and names.items[n_names - 1].key == n.key) continue;
        names.items[n_names] = n;
        n_names += 1;
    }
    names.shrinkRetainingCapacity(n_names);

    // Move tree.
    var b = Builder{ .gpa = gpa, .min_elo = min_elo, .plies = plies, .edges = .init(gpa) };
    defer b.edges.deinit();
    const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer gpa.free(window);
    for (inputs.items) |path| {
        const f = try Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var fbuf: [1 << 16]u8 = undefined;
        var fr = f.readerStreaming(io, &fbuf);
        const before = b.used;
        if (std.mem.endsWith(u8, path, ".zst")) {
            var z = std.compress.zstd.Decompress.init(&fr.interface, window, .{});
            try b.readAll(&z.reader);
        } else {
            try b.readAll(&fr.interface);
        }
        out.print("{s}: +{d} games ({d} moves so far)\n", .{ path, b.used - before, b.edges.count() });
    }
    var edges: std.ArrayList(EdgeRec) = .empty;
    defer edges.deinit(gpa);
    var eit = b.edges.iterator();
    while (eit.next()) |e| {
        const c = e.value_ptr.*;
        if (c.white + c.draws + c.black >= min_games) try edges.append(gpa, .{ .key = e.key_ptr.*, .counts = c });
    }
    std.mem.sort(EdgeRec, edges.items, {}, edgeLess);

    // Write.
    const of = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer of.close(io);
    var obuf: [65536]u8 = undefined;
    var ow = of.writer(io, &obuf);
    const w = &ow.interface;
    try w.writeAll(MAGIC);
    inline for (.{ VERSION, @as(u32, @intCast(names.items.len)), @as(u32, @intCast(edges.items.len)), @as(u32, @intCast(strings.items.len)), @as(u32, @intCast(plies)) }) |v|
        try w.writeInt(u32, v, .little);
    try w.writeInt(u64, Position.startpos().key, .little);
    for (names.items) |n| {
        try w.writeInt(u64, n.key, .little);
        try w.writeAll(&n.eco);
        try w.writeByte(n.len);
        try w.writeInt(u32, n.off, .little);
    }
    for (edges.items) |e| {
        try w.writeInt(u64, e.key.key, .little);
        try w.writeInt(u16, e.key.move, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, e.counts.white, .little);
        try w.writeInt(u32, e.counts.draws, .little);
        try w.writeInt(u32, e.counts.black, .little);
    }
    try w.writeAll(strings.items);
    try w.flush();

    const ms = @max(t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds(), 1);
    out.print("\n{d} named positions; {d} of {d} games used, {d} moves (played in >= {d} games, first {d} plies) -> {s} ({d}s)\n", .{
        names.items.len, b.used, b.games, edges.items.len, min_games, plies, out_path, @divTrunc(ms, 1000),
    });
}

// ---------------------------------------------------------------------------
// The user's own games

pub const Record = struct {
    games: u32 = 0,
    wins: u32 = 0,
    draws: u32 = 0,
    losses: u32 = 0,
};

/// How the user has done from each position reached right after one of
/// their own moves, over the first plies of their games.
pub const Repertoire = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMap(u64, Record),
    user_buf: [64]u8 = undefined,
    user_len: usize = 0,
    games: u32 = 0,

    const PLIES = 30;

    pub fn user(r: *const Repertoire) []const u8 {
        return r.user_buf[0..r.user_len];
    }

    pub fn get(r: *const Repertoire, key: u64) ?Record {
        return r.map.get(key);
    }

    pub fn deinit(r: *Repertoire) void {
        r.map.deinit();
    }

    const Game = struct { white: []const u8, black: []const u8, result: []const u8, movetext: []const u8 };

    const Collector = struct {
        arena: std.mem.Allocator,
        games: std.ArrayList(Game) = .empty,

        fn onGame(c: *Collector, g: *const pgn.Game) !void {
            if (!g.isStandard()) return;
            try c.games.append(c.arena, .{
                .white = try c.arena.dupe(u8, g.header("White") orelse ""),
                .black = try c.arena.dupe(u8, g.header("Black") orelse ""),
                .result = try c.arena.dupe(u8, g.header("Result") orelse "*"),
                .movetext = try c.arena.dupe(u8, g.movetext),
            });
        }
    };

    /// Reads `path` (a PGN file, or a directory of them). `user` is matched
    /// against White/Black; empty = whoever plays in most of the games.
    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8, user_name: []const u8) !Repertoire {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var c = Collector{ .arena = arena };

        if (Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) |dir_| {
            var dir = dir_;
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |e| {
                if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".pgn")) continue;
                const bytes = dir.readFileAlloc(io, e.name, arena, .limited(16 << 20)) catch continue;
                var r: Io.Reader = .fixed(bytes);
                try pgn.readGames(gpa, &r, &c, Collector.onGame);
            }
        } else |_| {
            const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20));
            var r: Io.Reader = .fixed(bytes);
            try pgn.readGames(gpa, &r, &c, Collector.onGame);
        }

        var rep = Repertoire{ .gpa = gpa, .map = .init(gpa) };
        errdefer rep.deinit();
        const who = if (user_name.len > 0) user_name else mostFrequent(arena, c.games.items) catch "";
        rep.user_len = @min(who.len, rep.user_buf.len);
        @memcpy(rep.user_buf[0..rep.user_len], who[0..rep.user_len]);
        if (who.len == 0) return rep;

        for (c.games.items) |g| {
            const as_white = std.ascii.eqlIgnoreCase(g.white, who);
            if (!as_white and !std.ascii.eqlIgnoreCase(g.black, who)) continue;
            const color: bb.Color = if (as_white) bb.WHITE else bb.BLACK;
            const score: u2 = if (std.mem.eql(u8, g.result, "1/2-1/2")) 1 else if (std.mem.eql(u8, g.result, if (as_white) "1-0" else "0-1")) 2 else if (std.mem.eql(u8, g.result, if (as_white) "0-1" else "1-0")) 0 else continue;
            rep.games += 1;
            var seen: [PLIES]u64 = undefined;
            var n_seen: usize = 0;
            var pos = Position.startpos();
            var it = pgn.SanIterator.init(g.movetext);
            for (0..PLIES) |_| {
                const tok = it.next() orelse break;
                const m = play.parseMove(&pos, tok) orelse break;
                const mover = pos.side;
                pos = pos.makeMove(m);
                if (mover != color or std.mem.indexOfScalar(u64, seen[0..n_seen], pos.key) != null) continue;
                seen[n_seen] = pos.key;
                n_seen += 1;
                const gop = try rep.map.getOrPut(pos.key);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.games += 1;
                switch (score) {
                    2 => gop.value_ptr.wins += 1,
                    1 => gop.value_ptr.draws += 1,
                    else => gop.value_ptr.losses += 1,
                }
            }
        }
        return rep;
    }

    fn mostFrequent(arena: std.mem.Allocator, games: []const Game) ![]const u8 {
        var counts = std.StringHashMap(u32).init(arena);
        var best: []const u8 = "";
        var best_n: u32 = 0;
        for (games) |g| for ([2][]const u8{ g.white, g.black }) |n| {
            if (n.len == 0 or std.mem.eql(u8, n, "?")) continue;
            const gop = try counts.getOrPut(n);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > best_n) {
                best_n = gop.value_ptr.*;
                best = n;
            }
        };
        return best;
    }
};

test "openings book round trip" {
    const atk = @import("attacks.zig");
    atk.init();
    const gpa = std.testing.allocator;
    var b = Builder{ .gpa = gpa, .min_elo = 0, .plies = 6, .edges = .init(gpa) };
    defer b.edges.deinit();
    const sample =
        \\[Result "1-0"]
        \\
        \\1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 1-0
        \\
        \\[Result "0-1"]
        \\
        \\1. e4 c5 2. Nf3 d6 0-1
        \\
        \\[Result "1/2-1/2"]
        \\
        \\1. e4 e5 2. Nf3 Nf6 1/2-1/2
        \\
    ;
    var r: Io.Reader = .fixed(sample);
    try b.readAll(&r);
    try std.testing.expectEqual(@as(u64, 3), b.used);
    const start = Position.startpos();
    const e4 = play.parseMove(&start, "e4").?;
    const c = b.edges.get(.{ .key = start.key, .move = e4.data }).?;
    try std.testing.expectEqual(Counts{ .white = 1, .draws = 1, .black = 1 }, c);
}

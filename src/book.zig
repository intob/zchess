//! Opening book builder: streams PGN (plain or .zst), keeps standard games
//! where both players meet a rating floor, replays the opening with the
//! engine's own move parser and samples distinct positions from a ply window.
//! Output: one FEN per line, used by `datagen --book` and `match --book`.

const std = @import("std");
const Io = std.Io;
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const play = @import("play.zig");
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;

const Position = position.Position;

const help =
    \\usage: zchess book --out <book.fen> [options] <games.pgn[.zst]>...
    \\
    \\  --out <file>       output FEN file (one position per line)
    \\  --min-elo <n>      both players rated at least this (default 2000; 0 = any)
    \\  --min-ply <n>      earliest ply to sample (default 8)
    \\  --max-ply <n>      latest ply to sample (default 20)
    \\  --per-game <n>     positions sampled per game (default 3)
    \\  --seed <n>         sampling seed (default 1)
    \\
;

const Options = struct {
    min_elo: u32 = 2000,
    min_ply: usize = 8,
    max_ply: usize = 20,
    per_game: usize = 3,
};

const Stats = struct {
    games: u64 = 0,
    accepted: u64 = 0,
    bad_moves: u64 = 0,
    positions: u64 = 0,
};

/// Per-game header state.
const Game = struct {
    white_elo: u32 = 0,
    black_elo: u32 = 0,
    standard: bool = true,
    in_moves: bool = false,

    fn reset(g: *Game) void {
        g.* = .{};
    }
};

const Builder = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    rng: std.Random,
    seen: std.AutoHashMap(u64, void),
    out: *Io.Writer,
    stats: Stats = .{},
    game: Game = .{},
    moves: std.ArrayList(u8) = .empty,

    fn headerValue(text: []const u8) ?[]const u8 {
        const q1 = std.mem.indexOfScalar(u8, text, '"') orelse return null;
        const q2 = std.mem.lastIndexOfScalar(u8, text, '"') orelse return null;
        if (q2 <= q1) return null;
        return text[q1 + 1 .. q2];
    }

    fn line(b: *Builder, raw: []const u8) !void {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len > 0 and l[0] == '[') {
            // A header after movetext starts a new game.
            if (b.game.in_moves) try b.finishGame();
            if (std.mem.startsWith(u8, l, "[WhiteElo ")) b.game.white_elo = std.fmt.parseInt(u32, headerValue(l) orelse "0", 10) catch 0;
            if (std.mem.startsWith(u8, l, "[BlackElo ")) b.game.black_elo = std.fmt.parseInt(u32, headerValue(l) orelse "0", 10) catch 0;
            if (std.mem.startsWith(u8, l, "[Variant ")) {
                const v = headerValue(l) orelse "";
                if (!std.ascii.eqlIgnoreCase(v, "standard")) b.game.standard = false;
            }
            // Games from a custom start position (Chess960, studies) don't fit.
            if (std.mem.startsWith(u8, l, "[SetUp \"1\"") or std.mem.startsWith(u8, l, "[FEN ")) b.game.standard = false;
            return;
        }
        if (l.len == 0) return;
        b.game.in_moves = true;
        try b.moves.appendSlice(b.gpa, l);
        try b.moves.append(b.gpa, ' ');
    }

    fn finishGame(b: *Builder) !void {
        defer {
            b.game.reset();
            b.moves.clearRetainingCapacity();
        }
        b.stats.games += 1;
        if (!b.game.standard) return;
        if (b.opts.min_elo > 0 and (b.game.white_elo < b.opts.min_elo or b.game.black_elo < b.opts.min_elo)) return;

        var candidates: [64]Position = undefined;
        var n_cand: usize = 0;
        var pos = Position.startpos();
        var ply: usize = 0;
        var depth: usize = 0; // comment/variation nesting
        var it = std.mem.tokenizeAny(u8, b.moves.items, " \t\n");
        while (it.next()) |tok_raw| {
            if (ply >= b.opts.max_ply) break;
            var tok = tok_raw;
            // Skip { comments } and ( variations ); tokens may straddle the brackets.
            if (depth > 0 or tok[0] == '{' or tok[0] == '(') {
                for (tok) |ch| switch (ch) {
                    '{', '(' => depth += 1,
                    '}', ')' => depth -|= 1,
                    else => {},
                };
                continue;
            }
            if (tok[0] == '$') continue; // NAG
            // Move numbers: "12." or "12..." possibly glued to the move ("12.e4").
            if (std.ascii.isDigit(tok[0])) {
                if (std.mem.eql(u8, tok, "1-0") or std.mem.eql(u8, tok, "0-1") or std.mem.eql(u8, tok, "1/2-1/2")) break;
                const dot = std.mem.lastIndexOfScalar(u8, tok, '.') orelse continue;
                tok = tok[dot + 1 ..];
                if (tok.len == 0) continue;
            }
            if (std.mem.eql(u8, tok, "*")) break;
            const m = play.parseMove(&pos, tok) orelse {
                b.stats.bad_moves += 1;
                return;
            };
            pos = pos.makeMove(m);
            ply += 1;
            if (ply >= b.opts.min_ply and !pos.inCheck() and n_cand < candidates.len) {
                var list = movegen.MoveList{};
                movegen.generate(&pos, &list, .all);
                if (list.len > 0) {
                    candidates[n_cand] = pos;
                    n_cand += 1;
                }
            }
        }
        if (n_cand == 0) return;
        b.stats.accepted += 1;

        // Sample up to per_game distinct positions without replacement.
        var k: usize = 0;
        while (k < b.opts.per_game and n_cand > 0) : (k += 1) {
            const i = b.rng.uintLessThan(usize, n_cand);
            const p = candidates[i];
            candidates[i] = candidates[n_cand - 1];
            n_cand -= 1;
            const gop = try b.seen.getOrPut(p.key);
            if (gop.found_existing) continue;
            var buf: [128]u8 = undefined;
            try b.out.print("{s}\n", .{p.toFen(&buf)});
            b.stats.positions += 1;
        }
    }

    fn readAll(b: *Builder, r: *Io.Reader) !void {
        while (true) {
            const l = r.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // Absurdly long line: drop it and the game it belongs to.
                    _ = try r.discardDelimiterInclusive('\n');
                    b.game.standard = false;
                    continue;
                },
                else => return err,
            } orelse break;
            try b.line(l);
        }
        if (b.game.in_moves) try b.finishGame();
        b.game.reset();
        b.moves.clearRetainingCapacity();
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var opts = Options{};
    var out_path: []const u8 = "";
    var seed: u64 = 1;
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    while (p.next()) |a| {
        if (p.flag(a, "--out")) |v| out_path = v
        else if (p.int(u32, a, "--min-elo")) |v| opts.min_elo = v
        else if (p.int(usize, a, "--min-ply")) |v| opts.min_ply = v
        else if (p.int(usize, a, "--max-ply")) |v| opts.max_ply = v
        else if (p.int(usize, a, "--per-game")) |v| opts.per_game = @max(v, 1)
        else if (p.int(u64, a, "--seed")) |v| seed = v
        else if (a[0] != '-') try inputs.append(gpa, a)
        else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (out_path.len == 0 or inputs.items.len == 0) {
        out.print("{s}", .{help});
        return;
    }

    const of = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer of.close(io);
    var obuf: [65536]u8 = undefined;
    var ow = of.writer(io, &obuf);

    var prng = std.Random.DefaultPrng.init(seed);
    var b = Builder{ .gpa = gpa, .opts = opts, .rng = prng.random(), .seen = .init(gpa), .out = &ow.interface };
    defer b.seen.deinit();
    defer b.moves.deinit(gpa);

    const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer gpa.free(window);
    const t0 = Io.Clock.awake.now(io);

    for (inputs.items) |path| {
        const f = try Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var fbuf: [1 << 16]u8 = undefined;
        var fr = f.readerStreaming(io, &fbuf);
        const before = b.stats;
        if (std.mem.endsWith(u8, path, ".zst")) {
            var z = std.compress.zstd.Decompress.init(&fr.interface, window, .{});
            try b.readAll(&z.reader);
        } else {
            try b.readAll(&fr.interface);
        }
        out.print("{s}: {d} games, {d} accepted, +{d} positions\n", .{
            path, b.stats.games - before.games, b.stats.accepted - before.accepted, b.stats.positions - before.positions,
        });
    }
    try ow.interface.flush();
    const ms = @max(t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds(), 1);
    out.print("\n{d} games read, {d} accepted, {d} with unparsable moves; {d} distinct positions -> {s} ({d}s)\n", .{
        b.stats.games, b.stats.accepted, b.stats.bad_moves, b.stats.positions, out_path, @divTrunc(ms, 1000),
    });
}

/// Load a FEN-per-line book into memory.
pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]Position {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    var list: std.ArrayList(Position) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |l| {
        const pos = Position.fromFen(std.mem.trim(u8, l, " \r")) catch continue;
        try list.append(gpa, pos);
    }
    if (list.items.len == 0) return error.EmptyBook;
    return list.toOwnedSlice(gpa);
}

test "pgn parsing" {
    const atk = @import("attacks.zig");
    atk.init();
    const gpa = std.testing.allocator;
    var outbuf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&outbuf);
    var prng = std.Random.DefaultPrng.init(1);
    var b = Builder{ .gpa = gpa, .opts = .{ .min_elo = 2000, .min_ply = 4, .max_ply = 6, .per_game = 10 }, .rng = prng.random(), .seen = .init(gpa), .out = &w };
    defer b.seen.deinit();
    defer b.moves.deinit(gpa);
    const pgn =
        \\[Event "Test"]
        \\[WhiteElo "2500"]
        \\[BlackElo "2400"]
        \\
        \\1. e4 { [%clk 1:00:00] } 1... c5 { comment
        \\spanning lines } 2. Nf3 (2. c3 d5) 2... d6 $1 3. d4 cxd4 4. Nxd4 Nf6 1-0
        \\
        \\[Event "Low rated"]
        \\[WhiteElo "1500"]
        \\[BlackElo "2400"]
        \\
        \\1. d4 d5 2. c4 e6 3. Nc3 Nf6 1-0
        \\
    ;
    var r: Io.Reader = .fixed(pgn);
    try b.readAll(&r);
    try std.testing.expectEqual(@as(u64, 2), b.stats.games);
    try std.testing.expectEqual(@as(u64, 1), b.stats.accepted);
    try std.testing.expectEqual(@as(u64, 3), b.stats.positions); // plies 4, 5, 6
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "rnbqkbnr/pp2pppp/3p4/2p5/3PP3/5N2/PPP2PPP/RNBQKB1R b KQkq") != null);
}

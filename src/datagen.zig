//! Self-play data generation: many threads play node-limited games from
//! random balanced openings and record quiet positions with search scores
//! and the final game result.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const game = @import("game.zig");
const cli = @import("cli.zig");
const Record = @import("data.zig").Record;
const TT = @import("tt.zig").TT;
const Output = @import("output.zig").Output;

const Position = position.Position;

const help =
    \\usage: zchess datagen --out <file> [options]
    \\
    \\  --out <file>       output file (records are appended)
    \\  --positions <n>    stop after roughly this many positions (default 1000000)
    \\  --nodes <n>        soft node limit per move (default 5000)
    \\  --threads <n>      worker threads (default: all cores)
    \\  --net <file|hce>   evaluation to play with (default: embedded net, else hce)
    \\  --seed <n>         random seed (default: from the clock)
    \\  --book <file>      start games from positions in this FEN file (see `zchess book`)
    \\
;

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    net: ?*const nnue.Network,
    book: ?[]const Position,
    file: Io.File,
    offset: u64,
    mutex: Io.Mutex = .init,
    target: u64,
    nodes: u64,
    seed: u64,
    positions: std.atomic.Value(u64) = .init(0),
    games: std.atomic.Value(u64) = .init(0),
    wins: std.atomic.Value(u64) = .init(0),
    draws: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn done(c: *Ctx) bool {
        return c.positions.load(.monotonic) >= c.target or c.failed.load(.monotonic);
    }

    fn write(c: *Ctx, recs: []const Record) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const bytes = std.mem.sliceAsBytes(recs);
        c.file.writePositionalAll(c.io, bytes, c.offset) catch |err| {
            std.debug.print("write failed: {s}\n", .{@errorName(err)});
            c.failed.store(true, .monotonic);
            return;
        };
        c.offset += bytes.len;
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var out_path: []const u8 = "";
    var target: u64 = 1_000_000;
    var nodes: u64 = 5000;
    var threads: usize = std.Thread.getCpuCount() catch 4;
    var net_path: []const u8 = "";
    var seed: u64 = @truncate(@as(u96, @bitCast(Io.Clock.real.now(io).toNanoseconds())));
    var book_path: []const u8 = "";
    while (p.next()) |a| {
        if (p.flag(a, "--out")) |v| out_path = v
        else if (p.int(u64, a, "--positions")) |v| target = v
        else if (p.int(u64, a, "--nodes")) |v| nodes = v
        else if (p.int(usize, a, "--threads")) |v| threads = @max(v, 1)
        else if (p.flag(a, "--net")) |v| net_path = v
        else if (p.int(u64, a, "--seed")) |v| seed = v
        else if (p.flag(a, "--book")) |v| book_path = v
        else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (out_path.len == 0) {
        out.print("{s}", .{help});
        return;
    }

    const net = try cli.loadNet(gpa, io, net_path);
    const book: ?[]const Position = if (book_path.len > 0) try @import("book.zig").load(gpa, io, book_path) else null;
    const file = try Io.Dir.cwd().createFile(io, out_path, .{ .truncate = false });
    defer file.close(io);
    const start_len = try file.length(io);
    const offset = start_len - start_len % @sizeOf(Record);

    var ctx = Ctx{ .io = io, .gpa = gpa, .net = net, .book = book, .file = file, .offset = offset, .target = target, .nodes = nodes, .seed = seed };
    out.print("datagen: {d} positions, {d} nodes/move, {d} threads, eval {s}, openings {s}, appending to {s} ({d} existing records)\n", .{
        target, nodes, threads, if (net != null) "nnue" else "hce", if (book != null) book_path else "random", out_path, offset / @sizeOf(Record),
    });

    const t0 = Io.Clock.awake.now(io);
    const workers = try gpa.alloc(std.Thread, threads);
    defer gpa.free(workers);
    for (workers, 0..) |*w, i| w.* = try std.Thread.spawn(.{}, worker, .{ &ctx, i });

    while (!ctx.done()) {
        io.sleep(.fromSeconds(5), .awake) catch {};
        const secs = @max(t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds(), 1);
        const n = ctx.positions.load(.monotonic);
        const g = ctx.games.load(.monotonic);
        out.print("\r{d} positions  {d} games  {d} pos/s  W/D {d:.1}%/{d:.1}%   ", .{
            n, g, @divTrunc(@as(i64, @intCast(n)) * 1000, secs),
            pct(ctx.wins.load(.monotonic), g), pct(ctx.draws.load(.monotonic), g),
        });
    }
    for (workers) |w| w.join();
    const secs = @max(t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds(), 1);
    out.print("\ndone: {d} positions from {d} games in {d}s\n", .{ ctx.positions.load(.monotonic), ctx.games.load(.monotonic), @divTrunc(secs, 1000) });
    if (ctx.failed.load(.monotonic)) return error.WriteFailed;
}

fn pct(a: u64, b: u64) f64 {
    if (b == 0) return 0;
    return @as(f64, @floatFromInt(a)) * 100.0 / @as(f64, @floatFromInt(b));
}

fn worker(ctx: *Ctx, tid: usize) void {
    workerImpl(ctx, tid) catch |err| {
        std.debug.print("datagen worker {d} failed: {s}\n", .{ tid, @errorName(err) });
        ctx.failed.store(true, .monotonic);
    };
}

fn workerImpl(ctx: *Ctx, tid: usize) !void {
    var tt = try TT.init(ctx.gpa, 16);
    defer tt.deinit(ctx.gpa);
    var stop = std.atomic.Value(bool).init(false);
    const s = try search.Searcher.create(ctx.gpa, ctx.io, &tt, ctx.net, &stop);
    defer ctx.gpa.destroy(s);
    var prng = std.Random.DefaultPrng.init(ctx.seed ^ (@as(u64, tid) *% 0x9E3779B97F4A7C15));
    const rng = prng.random();

    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(ctx.gpa);
    var recs: std.ArrayList(Record) = .empty;
    defer recs.deinit(ctx.gpa);

    while (!ctx.done()) {
        var pos = game.balancedOpening(rng, s, 300, ctx.book);
        tt.clear();
        s.clearHistory();
        keys.clearRetainingCapacity();
        recs.clearRetainingCapacity();
        var adj = game.Adjudicator{};
        var ply: usize = 0;

        const outcome: game.Outcome = while (true) {
            if (game.terminal(&pos, keys.items)) |o| break o;
            s.setPosition(&pos, keys.items);
            const r = s.search(.{ .soft_nodes = ctx.nodes, .nodes = ctx.nodes * 20 });
            const white_score = if (pos.side == bb.WHITE) r.score else -r.score;
            if (adj.update(ply, white_score)) |o| break o;
            // Keep quiet positions only: the net should learn static
            // evaluation, not tactics that the search resolves anyway.
            if (!pos.inCheck() and !r.move.isNoisy() and @abs(r.score) < search.MATE_BOUND)
                try recs.append(ctx.gpa, Record.pack(&pos, white_score, @intCast(@min(ply, 65535))));
            try keys.append(ctx.gpa, pos.key);
            pos = pos.makeMove(r.move);
            ply += 1;
        };

        const result: u8 = switch (outcome) {
            .white => 2,
            .black => 0,
            .draw => 1,
        };
        for (recs.items) |*r| r.result = result;
        ctx.write(recs.items);
        _ = ctx.positions.fetchAdd(recs.items.len, .monotonic);
        _ = ctx.games.fetchAdd(1, .monotonic);
        if (outcome == .draw) _ = ctx.draws.fetchAdd(1, .monotonic) else _ = ctx.wins.fetchAdd(1, .monotonic);
    }
}

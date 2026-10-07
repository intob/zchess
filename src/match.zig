//! In-process engine match: two evaluations (NNUE files or the HCE) play
//! node-limited games from shared random openings with colours reversed,
//! reporting Elo with a 95% interval and an SPRT log-likelihood ratio.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const game = @import("game.zig");
const cli = @import("cli.zig");
const TT = @import("tt.zig").TT;
const Output = @import("output.zig").Output;

const Position = @import("position.zig").Position;

const help =
    \\usage: zchess match --a <net|hce> --b <net|hce> [options]
    \\
    \\  --a, --b <file|hce>  the two evaluations (A is the one being tested)
    \\  --games <n>          maximum games, played in colour-reversed pairs (default 400)
    \\  --nodes <n>          soft node limit per move (default 20000)
    \\  --threads <n>        concurrent games (default: all cores)
    \\  --sprt <e0,e1>       stop early when SPRT(elo0, elo1) concludes, alpha = beta = 0.05
    \\  --seed <n>           opening seed (default 1)
    \\  --book <file>        openings from a FEN file (see `zchess book`) instead of random moves
    \\
;

const Stats = struct {
    w: u64 = 0,
    d: u64 = 0,
    l: u64 = 0,

    fn n(s: Stats) f64 {
        return @floatFromInt(s.w + s.d + s.l);
    }

    fn score(s: Stats) f64 {
        return (@as(f64, @floatFromInt(s.w)) + 0.5 * @as(f64, @floatFromInt(s.d))) / @max(s.n(), 1);
    }

    fn variance(s: Stats) f64 {
        const sc = s.score();
        const w: f64 = @floatFromInt(s.w);
        const d: f64 = @floatFromInt(s.d);
        const l: f64 = @floatFromInt(s.l);
        return (w * (1 - sc) * (1 - sc) + d * (0.5 - sc) * (0.5 - sc) + l * sc * sc) / @max(s.n(), 1);
    }

    fn eloOf(sc: f64) f64 {
        const c = std.math.clamp(sc, 1e-6, 1 - 1e-6);
        return -400.0 * std.math.log10(1.0 / c - 1.0);
    }

    /// Elo estimate and half-width of its 95% confidence interval.
    fn elo(s: Stats) [2]f64 {
        const sc = s.score();
        const se = @sqrt(s.variance() / @max(s.n(), 1));
        const e = eloOf(sc);
        return .{ e, (eloOf(sc + 1.96 * se) - eloOf(sc - 1.96 * se)) / 2 };
    }

    /// Generalised SPRT log-likelihood ratio (normal approximation).
    fn llr(s: Stats, elo0: f64, elo1: f64) f64 {
        const v = s.variance();
        if (v <= 0 or s.n() < 2) return 0;
        const s0 = 1.0 / (1.0 + std.math.pow(f64, 10, -elo0 / 400.0));
        const s1 = 1.0 / (1.0 + std.math.pow(f64, 10, -elo1 / 400.0));
        return s.n() * (s1 - s0) * (2 * s.score() - s0 - s1) / (2 * v);
    }
};

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    out: *Output,
    net_a: ?*const nnue.Network,
    net_b: ?*const nnue.Network,
    pairs: u64,
    nodes: u64,
    seed: u64,
    sprt: ?[2]f64,
    book: ?[]const Position,
    next: std.atomic.Value(u64) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    stats: Stats = .{},
};

const LLR_BOUND = 2.944; // ln(0.95 / 0.05)

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var a_path: []const u8 = "";
    var b_path: []const u8 = "";
    var games: u64 = 400;
    var nodes: u64 = 20000;
    var threads: usize = std.Thread.getCpuCount() catch 4;
    var sprt: ?[2]f64 = null;
    var seed: u64 = 1;
    var book_path: []const u8 = "";
    while (p.next()) |a| {
        if (p.flag(a, "--a")) |v| a_path = v
        else if (p.flag(a, "--book")) |v| book_path = v
        else if (p.flag(a, "--b")) |v| b_path = v
        else if (p.int(u64, a, "--games")) |v| games = @max(v, 2)
        else if (p.int(u64, a, "--nodes")) |v| nodes = v
        else if (p.int(usize, a, "--threads")) |v| threads = @max(v, 1)
        else if (p.int(u64, a, "--seed")) |v| seed = v
        else if (p.flag(a, "--sprt")) |v| {
            var it = std.mem.tokenizeScalar(u8, v, ',');
            const e0 = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const e1 = std.fmt.parseFloat(f64, it.next() orelse "5") catch 5;
            sprt = .{ e0, e1 };
        } else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (a_path.len == 0 or b_path.len == 0) {
        out.print("{s}", .{help});
        return;
    }

    var ctx = Ctx{
        .io = io,
        .gpa = gpa,
        .out = out,
        .net_a = try cli.loadNet(gpa, io, a_path),
        .net_b = try cli.loadNet(gpa, io, b_path),
        .pairs = games / 2,
        .nodes = nodes,
        .seed = seed,
        .sprt = sprt,
        .book = if (book_path.len > 0) try @import("book.zig").load(gpa, io, book_path) else null,
    };
    out.print("match: A={s} vs B={s}, {d} games, {d} nodes/move, {d} threads\n", .{ a_path, b_path, ctx.pairs * 2, nodes, threads });

    const workers = try gpa.alloc(std.Thread, threads);
    defer gpa.free(workers);
    for (workers, 0..) |*w, i| w.* = try std.Thread.spawn(.{}, worker, .{ &ctx, i });
    for (workers) |w| w.join();

    const s = ctx.stats;
    const e = s.elo();
    out.print("\n\nA vs B: +{d} ={d} -{d}  score {d:.1}%  Elo {d:.1} +/- {d:.1}\n", .{ s.w, s.d, s.l, s.score() * 100, e[0], e[1] });
    if (sprt) |sp| {
        const l = s.llr(sp[0], sp[1]);
        const verdict = if (l >= LLR_BOUND) "H1 accepted (A is stronger)" else if (l <= -LLR_BOUND) "H0 accepted (A is not stronger)" else "inconclusive";
        out.print("SPRT [{d}, {d}]: LLR {d:.2} (bounds +/-{d:.2}) {s}\n", .{ sp[0], sp[1], l, LLR_BOUND, verdict });
    }
}

fn worker(ctx: *Ctx, tid: usize) void {
    workerImpl(ctx) catch |err| std.debug.print("match worker {d} failed: {s}\n", .{ tid, @errorName(err) });
}

fn workerImpl(ctx: *Ctx) !void {
    var tt_a = try TT.init(ctx.gpa, 16);
    defer tt_a.deinit(ctx.gpa);
    var tt_b = try TT.init(ctx.gpa, 16);
    defer tt_b.deinit(ctx.gpa);
    var stop = std.atomic.Value(bool).init(false);
    const sa = try search.Searcher.create(ctx.gpa, ctx.io, &tt_a, ctx.net_a, &stop);
    defer ctx.gpa.destroy(sa);
    const sb = try search.Searcher.create(ctx.gpa, ctx.io, &tt_b, ctx.net_b, &stop);
    defer ctx.gpa.destroy(sb);
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(ctx.gpa);

    while (!ctx.finished.load(.monotonic)) {
        const pair = ctx.next.fetchAdd(1, .monotonic);
        if (pair >= ctx.pairs) break;
        // The opening depends only on the seed and pair index, so reruns are reproducible.
        var prng = std.Random.DefaultPrng.init(ctx.seed *% 0x9E3779B97F4A7C15 +% pair);
        const opening = game.balancedOpening(prng.random(), sa, 200, ctx.book);

        var pair_stats = Stats{};
        for (0..2) |round| {
            const a_white = round == 0;
            const o = try playGame(ctx, &opening, if (a_white) sa else sb, if (a_white) sb else sa, &keys);
            switch (o) {
                .draw => pair_stats.d += 1,
                .white => if (a_white) {
                    pair_stats.w += 1;
                } else {
                    pair_stats.l += 1;
                },
                .black => if (a_white) {
                    pair_stats.l += 1;
                } else {
                    pair_stats.w += 1;
                },
            }
        }

        ctx.mutex.lockUncancelable(ctx.io);
        defer ctx.mutex.unlock(ctx.io);
        ctx.stats.w += pair_stats.w;
        ctx.stats.d += pair_stats.d;
        ctx.stats.l += pair_stats.l;
        const s = ctx.stats;
        const e = s.elo();
        if (ctx.sprt) |sp| {
            const l = s.llr(sp[0], sp[1]);
            ctx.out.print("\rgames {d}  +{d} ={d} -{d}  Elo {d:.1} +/- {d:.1}  LLR {d:.2}   ", .{ s.w + s.d + s.l, s.w, s.d, s.l, e[0], e[1], l });
            if (@abs(l) >= LLR_BOUND) ctx.finished.store(true, .monotonic);
        } else {
            ctx.out.print("\rgames {d}  +{d} ={d} -{d}  Elo {d:.1} +/- {d:.1}   ", .{ s.w + s.d + s.l, s.w, s.d, s.l, e[0], e[1] });
        }
    }
}

fn playGame(ctx: *Ctx, start: *const Position, white: *search.Searcher, black: *search.Searcher, keys: *std.ArrayList(u64)) !game.Outcome {
    for ([_]*search.Searcher{ white, black }) |s| {
        s.tt.clear();
        s.clearHistory();
    }
    keys.clearRetainingCapacity();
    var pos = start.*;
    var adj = game.Adjudicator{};
    var ply: usize = 0;
    while (true) {
        if (game.terminal(&pos, keys.items)) |o| return o;
        const s = if (pos.side == bb.WHITE) white else black;
        s.setPosition(&pos, keys.items);
        const r = s.search(.{ .soft_nodes = ctx.nodes, .nodes = ctx.nodes * 10 });
        const white_score = if (pos.side == bb.WHITE) r.score else -r.score;
        if (adj.update(ply, white_score)) |o| return o;
        try keys.append(ctx.gpa, pos.key);
        pos = pos.makeMove(r.move);
        ply += 1;
    }
}

const std = @import("std");
const Io = std.Io;
const atk = @import("attacks.zig");
const movegen = @import("movegen.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const uci = @import("uci.zig");
const datagen = @import("datagen.zig");
const train = @import("train.zig");
const match = @import("match.zig");
const play = @import("play.zig");
const art = @import("art.zig");
const viz = @import("viz.zig");
const book = @import("book.zig");
const review = @import("review.zig");
const cli = @import("cli.zig");
const TT = @import("tt.zig").TT;
const Output = @import("output.zig").Output;

const Position = position.Position;

const usage =
    \\zchess - chess engine with a self-trained NNUE, written in Zig
    \\
    \\usage: zchess [command] [options]
    \\
    \\  (no command)    UCI mode
    \\  play            play against the engine in the terminal (play --help)
    \\  bench [depth]   search a fixed position set (--net <file|hce>)
    \\  perft-suite     verify move generation against known perft counts
    \\  datagen         generate self-play training data   (datagen --help)
    \\  train           train an NNUE network               (train --help)
    \\  match           play two evaluations against each other (match --help)
    \\  art <file> <png> render fingerprint art from a file's hash (run by zig build)
    \\  viz <net.nnue>  render a "brain scan" poster of a network (viz --help)
    \\  book            build an opening book from PGN / Lichess .pgn.zst (book --help)
    \\  review          review a player's games: mistakes, blunders, annotated PGN (review --help)
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    atk.init();

    var out_buf: [8192]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &out_buf);
    var out = Output{ .io = io, .writer = &fw.interface };

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = if (args.len >= 2) args[1] else "";
    const rest = if (args.len >= 2) args[2..] else args[0..0];

    if (cmd.len == 0 or std.mem.eql(u8, cmd, "uci")) {
        const engine = try uci.Engine.init(gpa, io, &out);
        if (std.mem.eql(u8, cmd, "uci")) _ = try engine.command("uci");
        try engine.loop();
    } else if (std.mem.eql(u8, cmd, "bench")) {
        try bench(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "perft-suite")) {
        var ok = true;
        for (movegen.perft_suite) |c| {
            const pos = try Position.fromFen(c.fen);
            const t0 = Io.Clock.awake.now(io);
            const n = movegen.perft(&pos, c.depth);
            const ms = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
            ok = ok and n == c.nodes;
            out.print("{s:<6} d{d} {d:>11} nodes {d:>6}ms {d:>4} Mnps  {s}\n", .{ if (n == c.nodes) "OK" else "FAIL", c.depth, n, @as(u64, @intCast(ms)), n / @as(u64, @intCast(@max(ms, 1))) / 1000, c.fen });
        }
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "dump-magics")) {
        for ([_][]const u8{ "rook", "bishop" }, [_]*const [64]atk.Magic{ &atk.rook_magics, &atk.bishop_magics }) |name, ms| {
            out.print("const {s}_magic_numbers = [64]u64{{\n", .{name});
            for (ms) |m| out.print("    0x{x:0>16},\n", .{m.magic});
            out.print("}};\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "datagen")) {
        try datagen.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "train")) {
        try train.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "review")) {
        try review.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "book")) {
        try book.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "viz")) {
        try viz.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "art")) {
        try art.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "play")) {
        try play.run(gpa, io, &out, rest);
    } else if (std.mem.eql(u8, cmd, "match")) {
        try match.run(gpa, io, &out, rest);
    } else {
        out.print("{s}", .{usage});
    }
}

const bench_fens = [_][]const u8{
    position.START_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
    "2r3k1/pp3ppp/2n1b3/3pP3/3P4/2PB1N2/P4PPP/R5K1 w - - 0 20",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R2QKB1R w KQ - 0 8",
    "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1",
    "r2q1rk1/1b1nbppp/p2ppn2/1p6/3NP3/1BN1BP2/PPPQ2PP/2KR3R w - - 0 12",
    "8/8/4k3/8/2p5/8/B2K4/8 w - - 0 1",
    "3r1rk1/p4ppp/1qp1pn2/8/2PP4/1Q3NP1/P3PPKP/3RR3 b - - 0 18",
};

fn bench(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var depth: i32 = 11;
    var net_path: []const u8 = "";
    while (p.next()) |a| {
        if (p.flag(a, "--net")) |v| net_path = v else depth = std.fmt.parseInt(i32, a, 10) catch depth;
    }
    const net = try cli.loadNet(gpa, io, net_path);
    var tt = try TT.init(gpa, 16);
    var stop = std.atomic.Value(bool).init(false);
    const s = try search.Searcher.create(gpa, io, &tt, net, &stop);
    var total: u64 = 0;
    const t0 = Io.Clock.awake.now(io);
    for (bench_fens) |fen| {
        const pos = try Position.fromFen(fen);
        tt.clear();
        s.clearHistory();
        s.setPosition(&pos, &.{});
        const r = s.search(.{ .depth = depth });
        total += s.nodes;
        var b: [5]u8 = undefined;
        out.print("{s:<5} {d:>6} {d:>10}  {s}\n", .{ r.move.toUci(&b), r.score, s.nodes, fen });
    }
    const ms: u64 = @intCast(@max(t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds(), 1));
    out.print("\n{d} nodes {d} nps ({s})\n", .{ total, total * 1000 / ms, if (net != null) "nnue" else "hce" });
}

test {
    _ = movegen;
    _ = nnue;
    _ = search;
    _ = @import("data.zig");
    _ = play;
    _ = art;
    _ = viz;
    _ = book;
    _ = @import("pgn.zig");
    _ = review;
}

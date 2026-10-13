//! Network "brain scan" poster for a .nnue file.
//!
//! Top: the input board. Middle: two hemispheres, the side-to-move and the
//! opponent accumulators, each holding all hidden neurons at mirrored
//! positions (most important at the centre). Each neuron glows with its
//! contribution to the evaluation of the shown position: amber raises the
//! eval for the side to move, blue lowers it, dark means silent. Fibres run
//! from each piece to the firing neurons it drives hardest, and from the
//! strongest neurons down the stem to the output. Bottom: learned piece values
//! and square tables, measured by placing pieces on real positions and asking
//! the network for the difference.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const nnue = @import("nnue.zig");
const cli = @import("cli.zig");
const art = @import("art.zig");
const canvas = @import("canvas.zig");
const Output = @import("output.zig").Output;

const Position = position.Position;
const Canvas = canvas.Canvas;
const Rgb = canvas.Rgb;
const H = nnue.HIDDEN;

const W = 1400;
const HEIGHT = 1990;
const MID = W / 2;

const BG: Rgb = .{ 11, 11, 15 };
const TEXT: Rgb = .{ 218, 212, 202 };
const DIM: Rgb = .{ 120, 115, 128 };
const ACCENT: Rgb = .{ 224, 164, 88 };
const WARM: Rgb = .{ 255, 160, 60 };
const COOL: Rgb = .{ 70, 160, 255 };
const NEUTRAL: Rgb = .{ 36, 34, 42 };

const DEFAULT_FEN = "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R2QKB1R w KQ - 0 8";

// Board (input) geometry.
const SQ = 40;
const BOARD_X = MID - 4 * SQ;
const BOARD_Y = 128;

// Brain geometry.
const BRAIN_CY = 830.0;
const HEMI_RX = 290.0;
const HEMI_RY = 318.0;
const HEMI_DX = 306.0;
const STEM_TOP = 1100.0;
const OUT_Y = 1236.0;

fn hemiCx(hemi: usize) f32 {
    return if (hemi == 0) MID - HEMI_DX else MID + HEMI_DX;
}

// ---------------------------------------------------------------- noise

fn hash2(ix: i32, iy: i32, seed: u32) f32 {
    var h: u32 = @bitCast(ix *% 374761393 +% iy *% 668265263);
    h +%= seed *% 2246822519;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xFFFF)) / 65535.0;
}

fn vnoise(x: f32, y: f32, seed: u32) f32 {
    const x0 = @floor(x);
    const y0 = @floor(y);
    const ix: i32 = @intFromFloat(x0);
    const iy: i32 = @intFromFloat(y0);
    const fx = x - x0;
    const fy = y - y0;
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    const a = hash2(ix, iy, seed);
    const b = hash2(ix + 1, iy, seed);
    const c = hash2(ix, iy + 1, seed);
    const d = hash2(ix + 1, iy + 1, seed);
    return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy;
}

fn fbm(x: f32, y: f32, seed: u32) f32 {
    return vnoise(x, y, seed) * 0.55 + vnoise(x * 2.1, y * 2.1, seed + 1) * 0.3 + vnoise(x * 4.3, y * 4.3, seed + 2) * 0.15;
}

/// Normalised distance from the hemisphere centre with a lobed, brain-like
/// outline: < 1 inside. The medial side is flatter and the frontal end narrower.
fn hemiShape(hemi: usize, x: f32, y: f32) f32 {
    var dx = (x - hemiCx(hemi)) / HEMI_RX;
    const dy = (y - BRAIN_CY) / HEMI_RY;
    const medial = if (hemi == 0) dx > 0 else dx < 0;
    if (medial) dx *= 1.22;
    if (dy < 0) dx *= 1 + 0.08 * -dy;
    const theta = std.math.atan2(dy, dx);
    const lobes = 1 + 0.03 * @sin(3 * theta + @as(f32, @floatFromInt(hemi))) + 0.012 * @sin(7 * theta + 1);
    return @sqrt(dx * dx + dy * dy) / lobes;
}

fn drawBrain(c: *Canvas) void {
    for (0..2) |hemi| {
        const seed: u32 = @intCast(17 + hemi * 101);
        const x0: usize = @intFromFloat(hemiCx(hemi) - HEMI_RX * 1.15);
        const x1: usize = @intFromFloat(hemiCx(hemi) + HEMI_RX * 1.15);
        const y0: usize = @intFromFloat(BRAIN_CY - HEMI_RY * 1.12);
        const y1: usize = @intFromFloat(BRAIN_CY + HEMI_RY * 1.12);
        for (y0..y1) |y| for (x0..x1) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const r = hemiShape(hemi, fx, fy);
            if (r >= 1) continue;
            // Domain-warped contour lines read as gyri and sulci.
            const wx = fx + 40 * vnoise(fx * 0.01, fy * 0.01, seed + 7);
            const wy = fy + 40 * vnoise(fx * 0.01 + 5, fy * 0.01, seed + 9);
            const v = fbm(wx * 0.016, wy * 0.016, seed) * 10;
            const d = @abs(v - @round(v));
            const shade = 1 - std.math.pow(f32, r, 6) * 0.65;
            const base: Rgb = .{ 66, 48, 72 };
            var col = canvas.lerp(.{ 0, 0, 0 }, base, shade);
            if (d < 0.13) col = canvas.lerp(col, .{ 16, 11, 20 }, 1 - d / 0.13);
            if (r > 0.97) col = canvas.lerp(col, .{ 90, 70, 98 }, (r - 0.97) / 0.03);
            c.set(x, y, col);
        };
    }
    // Brain stem.
    var y: f32 = STEM_TOP - 20;
    while (y < OUT_Y) : (y += 1) {
        const t = (y - (STEM_TOP - 20)) / (OUT_Y - (STEM_TOP - 20));
        const half = (36 - 24 * t) * @sqrt(@min(1, t * 6 + 0.15));
        var x = MID - half;
        while (x <= MID + half) : (x += 1) {
            const e = @abs(x - MID) / half;
            const col = canvas.lerp(.{ 46, 34, 52 }, .{ 20, 15, 24 }, e * e);
            c.set(@intFromFloat(x), @intFromFloat(y), col);
        }
    }
}

// ---------------------------------------------------------------- scan

const Scan = struct {
    pos: Position,
    acc: nnue.Accumulator,
    bucket: usize,
    eval: i32,
    contrib: [2][H]f32, // [hemisphere][neuron], hemisphere 0 = side to move
    max_contrib: f32,
    order: [H]u16, // neurons by importance, most important first
    slot: [H]u16, // neuron -> rank
};

fn scan(net: *const nnue.Network, pos: *const Position) Scan {
    var s: Scan = undefined;
    s.pos = pos.*;
    nnue.refresh(net, &s.acc, pos);
    s.bucket = nnue.outputBucket(pos);
    s.eval = nnue.evaluate(net, &s.acc, pos);
    const stm = pos.side;
    s.max_contrib = 1;
    for (0..2) |hemi| {
        const persp: usize = if (hemi == 0) stm else stm ^ 1;
        for (0..H) |j| {
            const a: f32 = @floatFromInt(std.math.clamp(s.acc.v[persp][j], 0, nnue.QA));
            const w: f32 = @floatFromInt(net.out_w[s.bucket][hemi * H + j]);
            s.contrib[hemi][j] = a * a * w;
            s.max_contrib = @max(s.max_contrib, @abs(s.contrib[hemi][j]));
        }
    }
    var importance: [H]f32 = undefined;
    for (0..H) |j| {
        var sum: f32 = 0;
        for (0..nnue.BUCKETS) |b| sum += @floatFromInt(@abs(@as(i32, net.out_w[b][j])) + @abs(@as(i32, net.out_w[b][H + j])));
        importance[j] = sum;
        s.order[j] = @intCast(j);
    }
    std.mem.sort(u16, &s.order, &importance, struct {
        fn gt(imp: *const [H]f32, a: u16, b: u16) bool {
            return imp[a] > imp[b];
        }
    }.gt);
    for (s.order, 0..) |j, rank| s.slot[j] = @intCast(rank);
    return s;
}

/// Sunflower layout inside each hemisphere; rank 0 sits at the centre.
fn neuronPos(hemi: usize, rank: usize) [2]f32 {
    const golden = 2.399963;
    const fr: f32 = @floatFromInt(rank);
    const r = @sqrt((fr + 0.5) / @as(f32, H)) * 0.82;
    const theta = fr * golden;
    var x = r * HEMI_RX * @cos(theta);
    const y = r * HEMI_RY * @sin(theta);
    if (hemi == 1) x = -x; // mirror so a neuron sits at the same spot in both halves
    return .{ hemiCx(hemi) + x, BRAIN_CY + y };
}

fn squareCenter(sq: bb.Square) [2]f32 {
    const f: f32 = @floatFromInt(bb.fileOf(sq));
    const r: f32 = @floatFromInt(bb.rankOf(sq));
    return .{ BOARD_X + (f + 0.5) * SQ, BOARD_Y + (7.5 - r) * SQ };
}

fn drawFibres(c: *Canvas, net: *const nnue.Network, s: *const Scan) void {
    const stm = s.pos.side;
    var occ = s.pos.occupied();
    while (occ != 0) {
        const sq = bb.popLsb(&occ);
        const pc = s.pos.board[sq];
        const from = squareCenter(sq);
        for (0..2) |hemi| {
            const persp: bb.Color = if (hemi == 0) stm else stm ^ 1;
            const row = net.ft_w[nnue.featureIndex(persp, s.acc.view[persp], pc, sq) * H ..][0..H];
            // The 5 firing neurons this piece drives hardest.
            var best: [5]usize = .{ 0, 0, 0, 0, 0 };
            var best_w: [5]i32 = .{ -1, -1, -1, -1, -1 };
            var max_w: i32 = 1;
            for (0..H) |j| {
                const w: i32 = @intCast(@abs(@as(i32, row[j])));
                max_w = @max(max_w, w);
                if (s.acc.v[persp][j] <= 0) continue;
                var k: usize = 5;
                while (k > 0 and w > best_w[k - 1]) : (k -= 1) {}
                if (k < 5) {
                    var m: usize = 4;
                    while (m > k) : (m -= 1) {
                        best[m] = best[m - 1];
                        best_w[m] = best_w[m - 1];
                    }
                    best[k] = j;
                    best_w[k] = w;
                }
            }
            for (best, best_w) |j, w| {
                if (w < 0) continue;
                const to = neuronPos(hemi, s.slot[j]);
                const ctrl: [2]f32 = .{ from[0] * 0.55 + to[0] * 0.45, (from[1] + to[1]) / 2 - 60 };
                const rel = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(max_w));
                c.curve(from, ctrl, to, if (row[j] > 0) WARM else COOL, 0.05 + 0.22 * rel);
            }
        }
    }

    // Stem fibres from the strongest contributors to the output.
    var top: [64]struct { hemi: usize, j: usize, v: f32 } = undefined;
    var n: usize = 0;
    for (0..2) |hemi| for (0..H) |j| {
        const v = @abs(s.contrib[hemi][j]);
        if (n < top.len) {
            top[n] = .{ .hemi = hemi, .j = j, .v = v };
            n += 1;
        } else {
            var weakest: usize = 0;
            for (top, 0..) |t, k| if (t.v < top[weakest].v) {
                weakest = k;
            };
            if (v > top[weakest].v) top[weakest] = .{ .hemi = hemi, .j = j, .v = v };
        }
    };
    const out: [2]f32 = .{ MID, OUT_Y };
    for (top[0..n]) |t| {
        if (t.v <= 0) continue;
        const from = neuronPos(t.hemi, s.slot[t.j]);
        const ctrl: [2]f32 = .{ from[0] * 0.25 + MID * 0.75, from[1] * 0.35 + OUT_Y * 0.65 };
        const rel = t.v / s.max_contrib;
        c.curve(from, ctrl, out, if (s.contrib[t.hemi][t.j] > 0) WARM else COOL, 0.06 + 0.4 * rel);
    }
}

fn drawNeurons(c: *Canvas, s: *const Scan) void {
    for (0..2) |hemi| for (0..H) |j| {
        const p = neuronPos(hemi, s.slot[j]);
        const v = s.contrib[hemi][j];
        if (v == 0) {
            c.glow(p[0], p[1], 1.1, .{ 110, 96, 124 }, 0.35);
            continue;
        }
        const t = @sqrt(@abs(v) / s.max_contrib);
        const col = if (v > 0) WARM else COOL;
        c.glow(p[0], p[1], 2 + 7 * t, col, 0.18 + 0.85 * t);
        c.glow(p[0], p[1], 1.0, .{ 255, 250, 240 }, 0.15 + 0.6 * t);
    };
    const out_col = if (s.eval >= 0) WARM else COOL;
    c.glow(MID, OUT_Y, 16, out_col, 0.9);
    c.glow(MID, OUT_Y, 5, .{ 255, 250, 240 }, 0.8);
}

fn drawBoard(c: *Canvas, pos: *const Position) void {
    c.rect(BOARD_X - 3, BOARD_Y - 3, 8 * SQ + 6, 8 * SQ + 6, .{ 70, 64, 78 });
    for (0..64) |i| {
        const sq: bb.Square = @intCast(i);
        const f: usize = bb.fileOf(sq);
        const r: usize = bb.rankOf(sq);
        const x0 = BOARD_X + f * SQ;
        const y0 = BOARD_Y + (7 - r) * SQ;
        c.rect(x0, y0, SQ, SQ, if ((f + r) % 2 == 1) .{ 66, 62, 74 } else .{ 42, 39, 49 });
        const pc = pos.board[sq];
        if (pc == bb.NO_PIECE) continue;
        const white = bb.pieceColor(pc) == bb.WHITE;
        const fill: Rgb = if (white) .{ 242, 238, 228 } else .{ 22, 21, 26 };
        const outline: Rgb = if (white) .{ 18, 17, 20 } else .{ 160, 154, 168 };
        const sprite = art.sprites[bb.pieceType(pc)];
        for (0..16) |sy| for (0..16) |sx| {
            const col: ?Rgb = switch (sprite[sy][sx]) {
                'o' => outline,
                'x' => fill,
                else => null,
            };
            if (col) |cc| c.rect(x0 + 4 + sx * 2, y0 + 4 + sy * 2, 2, 2, cc);
        };
    }
}

// ---------------------------------------------------------------- learned tables

const middlegame_bases = [_][]const u8{
    "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R2QKB1R w KQ - 0 8",
    "r2q1rk1/1b1nbppp/p2ppn2/1p6/3NP3/1BN1BP2/PPPQ2PP/2KR3R w - - 0 12",
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
    "2r3k1/pp3ppp/2n1b3/3pP3/3P4/2PB1N2/P4PPP/R5K1 w - - 0 20",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "3r1rk1/p4ppp/1qp1pn2/8/2PP4/1Q3NP1/P3PPKP/3RR3 w - - 0 18",
    "rnbqkb1r/pp2pppp/3p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 2 5",
    "r1bq1rk1/ppp2ppp/2np1n2/2b1p3/2B1P3/2PP1N2/PP3PPP/RNBQ1RK1 w - - 0 7",
    "r2qr1k1/pp1nbppp/2p2n2/3p4/3P1B2/2NBP3/PPQ2PPP/R4RK1 w - - 0 12",
    "2rq1rk1/pb1nbppp/1p2pn2/2pp4/3P4/1PNBPN2/PB3PPP/2RQ1RK1 w - - 0 12",
};

const endgame_bases = [_][]const u8{
    "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
    "6k1/5ppp/8/8/8/8/5PPP/6K1 w - - 0 1",
    "8/2k5/3p4/8/8/4P3/5K2/8 w - - 0 1",
    "8/8/4k3/8/8/2K5/8/8 w - - 0 1",
    "8/pp3k2/8/8/8/8/PP3K2/8 w - - 0 1",
};

const Table = struct { map: [64]f32, valid: [64]bool, mean: f32 };

fn whiteEval(net: *const nnue.Network, pos: *const Position) f32 {
    const e = nnue.evaluateFresh(net, pos);
    return @floatFromInt(if (pos.side == bb.WHITE) e else -e);
}

/// Average eval change from adding a white piece of type `pt` on each square
/// (or, for the king, moving the white king there), over the base positions.
fn learnedTable(net: *const nnue.Network, bases: []const []const u8, pt: bb.PieceType) Table {
    var sum = [_]f32{0} ** 64;
    var cnt = [_]f32{0} ** 64;
    for (bases) |fen| {
        const base = Position.fromFen(fen) catch continue;
        const e0 = whiteEval(net, &base);
        for (0..64) |i| {
            const sq: bb.Square = @intCast(i);
            if (base.board[sq] != bb.NO_PIECE) continue;
            if (pt == bb.PAWN and (bb.rankOf(sq) == 0 or bb.rankOf(sq) == 7)) continue;
            var p = base;
            if (pt == bb.KING) p.removePiece(base.kingSq(bb.WHITE));
            p.addPiece(bb.makePiece(bb.WHITE, pt), sq);
            sum[i] += whiteEval(net, &p) - e0;
            cnt[i] += 1;
        }
    }
    var t: Table = undefined;
    var total: f32 = 0;
    var n: f32 = 0;
    for (0..64) |i| {
        t.valid[i] = cnt[i] > 0;
        t.map[i] = if (cnt[i] > 0) sum[i] / cnt[i] else 0;
        if (t.valid[i]) {
            total += t.map[i];
            n += 1;
        }
    }
    t.mean = if (n > 0) total / n else 0;
    return t;
}

fn diverging(v: f32) Rgb {
    const t = std.math.pow(f32, @min(@abs(v), 1), 0.8);
    return canvas.lerp(NEUTRAL, if (v >= 0) WARM else COOL, t);
}

fn drawTables(c: *Canvas, net: *const nnue.Network, y: usize, title: []const u8, bases: []const []const u8) void {
    c.text(52, y, title, 2, ACCENT);
    const names = [6][]const u8{ "PAWN", "KNIGHT", "BISHOP", "ROOK", "QUEEN", "KING" };
    const cell = 20;
    const gap = (W - 2 * 52 - 6 * 8 * cell) / 5;
    for (0..6) |pti| {
        const t = learnedTable(net, bases, @intCast(pti));
        var maxdev: f32 = 1;
        for (0..64) |i| if (t.valid[i]) {
            maxdev = @max(maxdev, @abs(t.map[i] - t.mean));
        };
        const x0 = 52 + pti * (8 * cell + gap);
        const y0 = y + 30;
        for (0..64) |i| {
            const sq: bb.Square = @intCast(i);
            const col = if (t.valid[i]) diverging((t.map[i] - t.mean) / maxdev) else BG;
            c.rect(x0 + @as(usize, bb.fileOf(sq)) * cell, y0 + (7 - @as(usize, bb.rankOf(sq))) * cell, cell - 1, cell - 1, col);
        }
        var buf: [32]u8 = undefined;
        const caption = if (pti == bb.KING)
            names[pti]
        else
            std.fmt.bufPrint(&buf, "{s} {d}", .{ names[pti], @as(i32, @intFromFloat(@round(t.mean))) }) catch names[pti];
        c.text(x0, y0 + 8 * cell + 10, caption, 2, TEXT);
        var rbuf: [32]u8 = undefined;
        const range = std.fmt.bufPrint(&rbuf, "+/-{d}", .{@as(i32, @intFromFloat(@round(maxdev)))}) catch "";
        c.text(x0, y0 + 8 * cell + 30, range, 1, DIM);
    }
}

// ---------------------------------------------------------------- poster

fn centered(c: *Canvas, y: usize, s: []const u8, scale: usize, col: Rgb) void {
    label(c, MID - Canvas.textWidth(s, scale) / 2, y, s, scale, col);
}

/// Text on a background-coloured plate so fibres don't run through it.
fn label(c: *Canvas, x: usize, y: usize, s: []const u8, scale: usize, col: Rgb) void {
    const pad = 3 * scale;
    c.rect(x - pad, y - pad, Canvas.textWidth(s, scale) + 2 * pad, 7 * scale + 2 * pad, BG);
    c.text(x, y, s, scale, col);
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var net_path: []const u8 = "";
    var out_path: []const u8 = "";
    var fen: []const u8 = DEFAULT_FEN;
    while (p.next()) |a| {
        if (p.flag(a, "--fen")) |v| fen = v
        else if (p.flag(a, "--out")) |v| out_path = v
        else if (net_path.len == 0 and a[0] != '-') net_path = a
        else {
            out.print("usage: zchess viz <net.nnue> [--out <png>] [--fen <fen>]\n", .{});
            return;
        }
    }
    if (net_path.len == 0) {
        out.print("usage: zchess viz <net.nnue> [--out <png>] [--fen <fen>]\n", .{});
        return;
    }
    const default_out = if (std.mem.endsWith(u8, net_path, ".nnue"))
        try std.fmt.allocPrint(gpa, "{s}.png", .{net_path[0 .. net_path.len - 5]})
    else
        try std.fmt.allocPrint(gpa, "{s}.png", .{net_path});
    defer gpa.free(default_out);
    if (out_path.len == 0) out_path = default_out;

    const net = try nnue.loadFile(gpa, io, net_path);
    defer gpa.destroy(net);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, net_path, gpa, .limited(nnue.Network.file_size + 1));
    defer gpa.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const pos = Position.fromFen(fen) catch {
        out.print("invalid fen\n", .{});
        return;
    };
    const s = scan(net, &pos);

    var c = try Canvas.init(gpa, W, HEIGHT, BG);
    defer c.deinit(gpa);

    // Title.
    c.text(52, 40, "ZCHESS NNUE", 4, TEXT);
    const name = std.fs.path.basename(net_path);
    c.text(W - 52 - Canvas.textWidth(name, 3), 44, name, 3, ACCENT);
    var sub_buf: [128]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, "{d} -> {d}X2 -> 1   SCRELU   {d} OUTPUT BUCKETS   SHA256 {x}", .{ nnue.INPUTS, H, nnue.BUCKETS, digest[0..6] }) catch "";
    c.text(52, 86, sub, 2, DIM);

    drawBrain(&c);
    drawFibres(&c, net, &s);
    drawNeurons(&c, &s);
    drawBoard(&c, &pos);

    var buf: [128]u8 = undefined;
    centered(&c, BOARD_Y + 8 * SQ + 14, std.fmt.bufPrint(&buf, "INPUT: {d} PIECES = {d} OF 768 FEATURES ACTIVE PER SIDE", .{ bb.popcount(pos.occupied()), bb.popcount(pos.occupied()) }) catch "", 2, DIM);
    label(&c, @intFromFloat(hemiCx(0) - 84), @intFromFloat(BRAIN_CY + HEMI_RY + 18), "SIDE TO MOVE", 2, TEXT);
    label(&c, @intFromFloat(hemiCx(1) - 48), @intFromFloat(BRAIN_CY + HEMI_RY + 18), "OPPONENT", 2, TEXT);

    var active = [2]usize{ 0, 0 };
    for (0..2) |hemi| for (0..H) |j| {
        if (s.contrib[hemi][j] != 0) active[hemi] += 1;
    };
    const firing = std.fmt.bufPrint(&buf, "{d} + {d} OF {d} NEURONS FIRING", .{ active[0], active[1], 2 * H }) catch "";
    var firing_buf: [64]u8 = undefined;
    @memcpy(firing_buf[0..firing.len], firing);
    const firing_text = firing_buf[0..firing.len];

    const white_eval = if (pos.side == bb.WHITE) s.eval else -s.eval;
    const ev = std.fmt.bufPrint(&buf, "EVAL {s}{d}.{d:0>2} (WHITE)", .{ if (white_eval >= 0) "+" else "-", @abs(white_eval) / 100, @abs(white_eval) % 100 }) catch "";
    centered(&c, @as(usize, @intFromFloat(OUT_Y)) + 30, ev, 3, TEXT);

    centered(&c, @as(usize, @intFromFloat(OUT_Y)) + 66, firing_text, 2, DIM);

    // Legend.
    const ly: usize = @as(usize, @intFromFloat(OUT_Y)) + 96;
    c.glow(MID - 250, @floatFromInt(ly + 7), 6, WARM, 1);
    c.text(MID - 236, ly, "RAISES EVAL FOR SIDE TO MOVE", 2, DIM);
    c.glow(MID + 150, @floatFromInt(ly + 7), 6, COOL, 1);
    c.text(MID + 164, ly, "LOWERS IT", 2, DIM);

    drawTables(&c, net, 1400, "LEARNED VALUES AND SQUARE TABLES - MIDDLEGAME (CENTIPAWNS)", &middlegame_bases);
    drawTables(&c, net, 1670, "LEARNED VALUES AND SQUARE TABLES - ENDGAME", &endgame_bases);

    try c.savePng(gpa, io, out_path);
    out.print("{s} -> {s} (eval {d}, {d}+{d} neurons firing)\n", .{ net_path, out_path, white_eval, active[0], active[1] });
}

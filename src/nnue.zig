//! NNUE inference: (768 -> HIDDEN) x 2 perspectives -> 1, SCReLU activation,
//! 8 output buckets by piece count. Quantised i16 weights, NEON via @Vector.

const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const build_options = @import("build_options");

const Position = position.Position;

pub const INPUTS = 768;
/// Set at build time with -Dhidden= (default 256).
pub const HIDDEN: usize = build_options.hidden;
pub const BUCKETS = 8;
pub const QA = 255;
pub const QB = 64;
pub const SCALE = 400;

pub const MAGIC = "ZCNN";
pub const VERSION: u32 = 1;
pub const HEADER_SIZE = 16;

const LANES = 16;
const V16 = @Vector(LANES, i16);
const V32 = @Vector(LANES, i32);

pub const Network = struct {
    ft_w: [INPUTS * HIDDEN]i16 align(64),
    ft_b: [HIDDEN]i16 align(64),
    out_w: [BUCKETS][2 * HIDDEN]i16 align(64),
    out_b: [BUCKETS]i16,

    pub const file_size = HEADER_SIZE + 2 * (INPUTS * HIDDEN + HIDDEN + BUCKETS * 2 * HIDDEN + BUCKETS);

    pub fn loadBytes(net: *Network, bytes: []const u8) !void {
        if (bytes.len != file_size) return error.BadNetSize;
        if (!std.mem.eql(u8, bytes[0..4], MAGIC)) return error.BadNetMagic;
        const version = std.mem.readInt(u32, bytes[4..8], .little);
        const hidden = std.mem.readInt(u32, bytes[8..12], .little);
        const buckets = std.mem.readInt(u32, bytes[12..16], .little);
        if (version != VERSION or hidden != HIDDEN or buckets != BUCKETS) return error.BadNetShape;
        var off: usize = HEADER_SIZE;
        inline for (.{ "ft_w", "ft_b", "out_w", "out_b" }) |name| {
            const dst = std.mem.asBytes(&@field(net, name));
            @memcpy(dst, bytes[off..][0..dst.len]);
            off += dst.len;
        }
    }

    pub fn writeTo(net: *const Network, w: *std.Io.Writer) !void {
        var header: [HEADER_SIZE]u8 = undefined;
        @memcpy(header[0..4], MAGIC);
        std.mem.writeInt(u32, header[4..8], VERSION, .little);
        std.mem.writeInt(u32, header[8..12], HIDDEN, .little);
        std.mem.writeInt(u32, header[12..16], BUCKETS, .little);
        try w.writeAll(&header);
        inline for (.{ "ft_w", "ft_b", "out_w", "out_b" }) |name| {
            try w.writeAll(std.mem.asBytes(&@field(net, name)));
        }
    }
};

pub const embedded: ?[]const u8 = if (build_options.has_net) @embedFile("default_net") else null;

comptime {
    if (HIDDEN % LANES != 0) @compileError("-Dhidden must be a multiple of 16");
    if (embedded) |e| if (e.len != Network.file_size)
        @compileError("the -Dnet network doesn't match -Dhidden (wrong layer size)");
}

pub const Accumulator = struct {
    v: [2][HIDDEN]i16 align(64),
};

/// Feature index of `piece` on `sq` seen from `persp`'s side of the board.
pub inline fn featureIndex(persp: bb.Color, piece: bb.Piece, sq: bb.Square) usize {
    const rel_color: usize = bb.pieceColor(piece) ^ persp;
    const rel_sq: usize = if (persp == bb.BLACK) sq ^ 56 else sq;
    return (rel_color * 6 + bb.pieceType(piece)) * 64 + rel_sq;
}

pub inline fn outputBucket(pos: *const Position) usize {
    const n = bb.popcount(pos.occupied());
    return @min((n -| 2) / 4, BUCKETS - 1);
}

inline fn row(net: *const Network, feat: usize) *const [HIDDEN]i16 {
    return net.ft_w[feat * HIDDEN ..][0..HIDDEN];
}

pub fn refresh(net: *const Network, acc: *Accumulator, pos: *const Position) void {
    for (0..2) |pi| {
        const persp: bb.Color = @intCast(pi);
        acc.v[pi] = net.ft_b;
        var occ = pos.occupied();
        while (occ != 0) {
            const sq = bb.popLsb(&occ);
            const w = row(net, featureIndex(persp, pos.board[sq], sq));
            var i: usize = 0;
            while (i < HIDDEN) : (i += LANES) {
                const a: V16 = acc.v[pi][i..][0..LANES].*;
                const b: V16 = w[i..][0..LANES].*;
                acc.v[pi][i..][0..LANES].* = a +% b;
            }
        }
    }
}

/// dst = src + added features - removed features, for both perspectives.
pub fn update(net: *const Network, src: *const Accumulator, dst: *Accumulator, d: *const position.Dirty) void {
    for (0..2) |pi| {
        const persp: bb.Color = @intCast(pi);
        var adds: [2]*const [HIDDEN]i16 = undefined;
        var subs: [2]*const [HIDDEN]i16 = undefined;
        for (0..d.n_add) |k| adds[k] = row(net, featureIndex(persp, d.add[k].piece, d.add[k].sq));
        for (0..d.n_sub) |k| subs[k] = row(net, featureIndex(persp, d.sub[k].piece, d.sub[k].sq));

        var i: usize = 0;
        while (i < HIDDEN) : (i += LANES) {
            var v: V16 = src.v[pi][i..][0..LANES].*;
            for (adds[0..d.n_add]) |a| v +%= a[i..][0..LANES].*;
            for (subs[0..d.n_sub]) |s| v -%= s[i..][0..LANES].*;
            dst.v[pi][i..][0..LANES].* = v;
        }
    }
}

inline fn screluDot(acc: *const [HIDDEN]i16, w: *const [HIDDEN]i16) V32 {
    const zero: V16 = @splat(0);
    const qa: V16 = @splat(QA);
    var sum: V32 = @splat(0);
    var i: usize = 0;
    while (i < HIDDEN) : (i += LANES) {
        const a: V16 = acc[i..][0..LANES].*;
        const c = @min(@max(a, zero), qa);
        const ww: V16 = w[i..][0..LANES].*;
        // c * w fits in i16 because |w| <= 127 and c <= 255 (lizard SCReLU trick).
        const cw = c *% ww;
        sum +%= @as(V32, c) *% @as(V32, cw);
    }
    return sum;
}

/// Evaluation in centipawns from the side to move's point of view.
pub fn evaluate(net: *const Network, acc: *const Accumulator, pos: *const Position) i32 {
    const b = outputBucket(pos);
    const us = pos.side;
    const w = &net.out_w[b];
    const sum = screluDot(&acc.v[us], w[0..HIDDEN]) +% screluDot(&acc.v[us ^ 1], w[HIDDEN..][0..HIDDEN]);
    const total: i32 = @reduce(.Add, sum);
    const out = @divTrunc(total, QA) + net.out_b[b];
    return @divTrunc(out * SCALE, QA * QB);
}

/// Convenience full evaluation (refreshes a scratch accumulator).
pub fn evaluateFresh(net: *const Network, pos: *const Position) i32 {
    var acc: Accumulator = undefined;
    refresh(net, &acc, pos);
    return evaluate(net, &acc, pos);
}

pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*Network {
    const net = try gpa.create(Network);
    errdefer gpa.destroy(net);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(Network.file_size + 1));
    defer gpa.free(bytes);
    try net.loadBytes(bytes);
    return net;
}

pub fn loadEmbedded(gpa: std.mem.Allocator) !?*Network {
    const bytes = embedded orelse return null;
    const net = try gpa.create(Network);
    try net.loadBytes(bytes);
    return net;
}

test "incremental update matches refresh" {
    const atk = @import("attacks.zig");
    const movegen = @import("movegen.zig");
    atk.init();
    const gpa = std.testing.allocator;
    const net = try gpa.create(Network);
    defer gpa.destroy(net);
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    for (&net.ft_w) |*x| x.* = r.intRangeAtMost(i16, -60, 60);
    for (&net.ft_b) |*x| x.* = r.intRangeAtMost(i16, -60, 60);
    for (&net.out_w) |*bk| for (bk) |*x| {
        x.* = r.intRangeAtMost(i16, -127, 127);
    };
    for (&net.out_b) |*x| x.* = r.intRangeAtMost(i16, -1000, 1000);

    var pos = try Position.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    var acc: Accumulator = undefined;
    refresh(net, &acc, &pos);
    for (0..200) |_| {
        var list = movegen.MoveList{};
        movegen.generate(&pos, &list, .all);
        if (list.len == 0) break;
        const m = list.moves[r.uintLessThan(usize, list.len)];
        const child = pos.makeMove(m);
        var inc: Accumulator = undefined;
        update(net, &acc, &inc, &child.dirty);
        var fresh: Accumulator = undefined;
        refresh(net, &fresh, &child);
        try std.testing.expectEqualSlices(i16, &fresh.v[0], &inc.v[0]);
        try std.testing.expectEqualSlices(i16, &fresh.v[1], &inc.v[1]);
        pos = child;
        acc = inc;
    }
}

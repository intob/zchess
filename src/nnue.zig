//! NNUE inference: (768 x KING_BUCKETS -> HIDDEN) x 2 perspectives -> 1,
//! SCReLU activation, 8 output buckets by piece count. Quantised i16 weights,
//! NEON via @Vector.
//!
//! King buckets (built with -Dking-buckets=N): each perspective picks one of N
//! input weight sets by where its own king stands, and mirrors the board
//! left-right so that king is always on files a-d. 0 = the original layout
//! (one weight set, no mirroring, file format version 1).
//!
//! Int8 feature weights (built with -Dft8): the feature transformer stores i8
//! weights at QA = 128 instead of i16 at QA = 255, which halves the weight rows
//! the accumulator updates read; the output layer moves from QB = 64 to 128.
//! On gen7w's float net that is less quantisation error than the i16 layout
//! (6.4 cp mean vs 7.1). File format version 3, which always has the 20-byte
//! header.

const std = @import("std");
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const build_options = @import("build_options");

const Position = position.Position;

/// Set at build time with -Dking-buckets= (default 0; from the -Dnet header).
pub const KING_BUCKETS: usize = build_options.king_buckets;
const MIRROR = KING_BUCKETS != 0;
pub const INPUTS: usize = 768 * (if (MIRROR) KING_BUCKETS else 1);
/// Set at build time with -Dhidden= (default 256; from the -Dnet header).
pub const HIDDEN: usize = build_options.hidden;
pub const BUCKETS = 8;
/// Set at build time with -Dft8 (default false; from the -Dnet header).
pub const FT8 = build_options.ft8;
/// Feature-transformer weight type.
pub const FtW = if (FT8) i8 else i16;
pub const QA = if (FT8) 128 else 255;
pub const QB = if (FT8) 128 else 64;
pub const SCALE = 400;

pub const MAGIC = "ZCNN";
/// Version 2 adds a king-bucket count to the header; version 3 is int8 feature
/// weights (with the king-bucket count, which may be 0).
pub const VERSION: u32 = if (FT8) 3 else if (MIRROR) 2 else 1;
pub const HEADER_SIZE = if (FT8 or MIRROR) 20 else 16;

/// King bucket of each own-king square on files a-d (after mirroring),
/// rank 1 first. Finer near the back rank, where kings spend most of the game.
const king_layout: [32]u8 = switch (KING_BUCKETS) {
    0, 1 => .{0} ** 32,
    4 => .{
        0, 0, 1, 1,
        2, 2, 2, 2,
    } ++ .{3} ** 24,
    8 => .{
        0, 1, 2, 3,
        4, 4, 5, 5,
        6, 6, 6, 6,
    } ++ .{7} ** 20,
    16 => .{
        0,  1,  2,  3,
        4,  5,  6,  7,
        8,  8,  9,  9,
        10, 10, 11, 11,
        12, 12, 13, 13,
    } ++ .{ 14, 14, 15, 15 } ** 3,
    else => @compileError("-Dking-buckets must be 0, 1, 4, 8 or 16"),
};

const LANES = 16;
const V16 = @Vector(LANES, i16);
const V32 = @Vector(LANES, i32);

pub const Network = struct {
    ft_w: [INPUTS * HIDDEN]FtW align(64),
    ft_b: [HIDDEN]i16 align(64),
    out_w: [BUCKETS][2 * HIDDEN]i16 align(64),
    out_b: [BUCKETS]i16,

    pub const file_size = HEADER_SIZE + @sizeOf(FtW) * INPUTS * HIDDEN + 2 * (HIDDEN + BUCKETS * 2 * HIDDEN + BUCKETS);

    pub fn loadBytes(net: *Network, bytes: []const u8) !void {
        if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], MAGIC)) return error.BadNetMagic;
        const version = std.mem.readInt(u32, bytes[4..8], .little);
        const hidden = std.mem.readInt(u32, bytes[8..12], .little);
        const buckets = std.mem.readInt(u32, bytes[12..16], .little);
        if (version != VERSION or hidden != HIDDEN or buckets != BUCKETS) return error.BadNetShape;
        if (bytes.len != file_size) return error.BadNetSize;
        if (HEADER_SIZE == 20 and std.mem.readInt(u32, bytes[16..20], .little) != KING_BUCKETS) return error.BadNetShape;
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
        if (HEADER_SIZE == 20) std.mem.writeInt(u32, header[16..20], KING_BUCKETS, .little);
        try w.writeAll(&header);
        inline for (.{ "ft_w", "ft_b", "out_w", "out_b" }) |name| {
            try w.writeAll(std.mem.asBytes(&@field(net, name)));
        }
    }
};

pub const embedded: ?[]const u8 = if (build_options.has_net) @embedFile("default_net") else null;

comptime {
    // screluDot takes two vectors a step.
    if (HIDDEN % (2 * LANES) != 0) @compileError("-Dhidden must be a multiple of 32");
    // screluDot multiplies a clipped activation by an output weight in i16;
    // the trainer clips output weights to 1.98, so 1.98 * QB * QA must fit.
    if (QA * @round(1.98 * QB) > std.math.maxInt(i16)) @compileError("QA * QB too large for screluDot");
    if (embedded) |e| if (e.len != Network.file_size)
        @compileError("the -Dnet network doesn't match -Dhidden (wrong layer size)");
}

pub const Accumulator = struct {
    v: [2][HIDDEN]i16 align(64),
    /// King view each perspective was built for; a king move that changes it
    /// needs a refresh of that perspective.
    view: [2]KingView,
};

/// Which weight set a perspective uses, and whether it mirrors files.
pub const KingView = packed struct(u8) {
    bucket: u7 = 0,
    mirror: bool = false,

    pub inline fn eql(a: KingView, b: KingView) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

/// Accumulator cache for king-bucket refreshes (a "Finny table"): for each
/// perspective and king view, the accumulator last built for it and the
/// pieces it was built from. A king move into another view then adds and
/// removes only the pieces that changed since that view was last used,
/// instead of every piece. Empty without king buckets. Reset it whenever the
/// net changes.
pub const Cache = struct {
    entries: [2][VIEWS]Entry,

    const VIEWS = if (MIRROR) 2 * KING_BUCKETS else 0;
    const Entry = struct {
        v: [HIDDEN]i16 align(64),
        /// [color][piece type] bitboards the accumulator was built from.
        pieces: [2][6]u64,
    };

    /// Every entry to the empty board, so that its first use adds every piece.
    pub fn reset(c: *Cache, net: *const Network) void {
        for (&c.entries) |*persp| for (persp) |*e| {
            e.v = net.ft_b;
            e.pieces = std.mem.zeroes([2][6]u64);
        };
    }
};

/// The view of `persp`, whose own king stands on `ksq`.
pub inline fn kingView(persp: bb.Color, ksq: bb.Square) KingView {
    if (!MIRROR) return .{};
    const rel: u8 = if (persp == bb.BLACK) ksq ^ 56 else ksq;
    const mirror = rel & 7 >= 4;
    const folded = if (mirror) rel ^ 7 else rel;
    return .{ .bucket = @intCast(king_layout[(folded >> 3) * 4 + (folded & 7)]), .mirror = mirror };
}

pub inline fn positionView(persp: bb.Color, pos: *const Position) KingView {
    return if (MIRROR) kingView(persp, pos.kingSq(persp)) else .{};
}

/// Feature index of `piece` on `sq` seen from `persp`'s side of the board.
pub inline fn featureIndex(persp: bb.Color, view: KingView, piece: bb.Piece, sq: bb.Square) usize {
    const rel_color: usize = bb.pieceColor(piece) ^ persp;
    var rel_sq: usize = if (persp == bb.BLACK) sq ^ 56 else sq;
    if (view.mirror) rel_sq ^= 7;
    return @as(usize, view.bucket) * 768 + (rel_color * 6 + bb.pieceType(piece)) * 64 + rel_sq;
}

pub inline fn outputBucket(pos: *const Position) usize {
    const n = bb.popcount(pos.occupied());
    return @min((n -| 2) / 4, BUCKETS - 1);
}

inline fn row(net: *const Network, feat: usize) *const [HIDDEN]FtW {
    return net.ft_w[feat * HIDDEN ..][0..HIDDEN];
}

/// Lanes i.. of a weight row, widened to i16 (int8 rows sign-extend into the
/// add: saddw on NEON, vpmovsxbw on x86).
inline fn rowLanes(w: *const [HIDDEN]FtW, i: usize) V16 {
    return @as(@Vector(LANES, FtW), w[i..][0..LANES].*);
}

pub fn refresh(net: *const Network, acc: *Accumulator, pos: *const Position) void {
    refreshPerspective(net, acc, pos, bb.WHITE);
    refreshPerspective(net, acc, pos, bb.BLACK);
}

fn refreshPerspective(net: *const Network, acc: *Accumulator, pos: *const Position, persp: bb.Color) void {
    const view = positionView(persp, pos);
    acc.view[persp] = view;
    acc.v[persp] = net.ft_b;
    var occ = pos.occupied();
    while (occ != 0) {
        const sq = bb.popLsb(&occ);
        addRow(&acc.v[persp], row(net, featureIndex(persp, view, pos.board[sq], sq)));
    }
}

inline fn addRow(v: *[HIDDEN]i16, w: *const [HIDDEN]FtW) void {
    var i: usize = 0;
    while (i < HIDDEN) : (i += LANES) {
        const a: V16 = v[i..][0..LANES].*;
        v[i..][0..LANES].* = a +% rowLanes(w, i);
    }
}

inline fn subRow(v: *[HIDDEN]i16, w: *const [HIDDEN]FtW) void {
    var i: usize = 0;
    while (i < HIDDEN) : (i += LANES) {
        const a: V16 = v[i..][0..LANES].*;
        v[i..][0..LANES].* = a -% rowLanes(w, i);
    }
}

/// refreshPerspective through the cache: the same accumulator (the adds wrap,
/// so their order doesn't matter), from just the pieces that changed.
fn refreshCached(net: *const Network, cache: *Cache, acc: *Accumulator, pos: *const Position, persp: bb.Color) void {
    const view = positionView(persp, pos);
    const e = &cache.entries[persp][@as(usize, view.bucket) * 2 + @intFromBool(view.mirror)];
    for (0..2) |ci| {
        const c: bb.Color = @intCast(ci);
        for (0..6) |pti| {
            const pt: bb.PieceType = @intCast(pti);
            const pc = bb.makePiece(c, pt);
            const now = pos.piecesOf(c, pt);
            var add = now & ~e.pieces[c][pt];
            var sub = e.pieces[c][pt] & ~now;
            while (add != 0) addRow(&e.v, row(net, featureIndex(persp, view, pc, bb.popLsb(&add))));
            while (sub != 0) subRow(&e.v, row(net, featureIndex(persp, view, pc, bb.popLsb(&sub))));
            e.pieces[c][pt] = now;
        }
    }
    acc.v[persp] = e.v;
    acc.view[persp] = view;
}

/// dst = src + added features - removed features, for both perspectives, or a
/// fresh build (through `cache`) of a perspective whose king moved to another
/// view. `pos` is the position after the move (its `dirty` lists the changes).
pub fn update(net: *const Network, cache: *Cache, src: *const Accumulator, dst: *Accumulator, pos: *const Position) void {
    // A kernel per shape of change, so the row loops unroll with the counts
    // known: a quiet move or promotion, a capture (en passant too), castling.
    const d = &pos.dirty;
    switch (@as(u8, d.n_add) << 2 | d.n_sub) {
        1 << 2 | 1 => updateWith(1, 1, net, cache, src, dst, pos),
        1 << 2 | 2 => updateWith(1, 2, net, cache, src, dst, pos),
        2 << 2 | 2 => updateWith(2, 2, net, cache, src, dst, pos),
        else => unreachable,
    }
}

inline fn updateWith(comptime n_add: usize, comptime n_sub: usize, net: *const Network, cache: *Cache, src: *const Accumulator, dst: *Accumulator, pos: *const Position) void {
    const d = &pos.dirty;
    inline for (0..2) |pi| {
        const persp: bb.Color = pi;
        const view = positionView(persp, pos);
        if (MIRROR and !view.eql(src.view[persp])) {
            refreshCached(net, cache, dst, pos, persp);
        } else {
            dst.view[persp] = view;
            var adds: [n_add]*const [HIDDEN]FtW = undefined;
            var subs: [n_sub]*const [HIDDEN]FtW = undefined;
            inline for (0..n_add) |k| adds[k] = row(net, featureIndex(persp, view, d.add[k].piece, d.add[k].sq));
            inline for (0..n_sub) |k| subs[k] = row(net, featureIndex(persp, view, d.sub[k].piece, d.sub[k].sq));
            const from = &src.v[pi];
            const to = &dst.v[pi];
            var i: usize = 0;
            while (i < HIDDEN) : (i += LANES) {
                var v: V16 = from[i..][0..LANES].*;
                inline for (adds) |a| v +%= rowLanes(a, i);
                inline for (subs) |s| v -%= rowLanes(s, i);
                to[i..][0..LANES].* = v;
            }
        }
    }
}

inline fn screluDot(acc: *const [HIDDEN]i16, w: *const [HIDDEN]i16) V32 {
    const zero: V16 = @splat(0);
    const qa: V16 = @splat(QA);
    // Two sums so twice as many multiply-accumulates are in flight.
    var sums = [2]V32{ @splat(0), @splat(0) };
    var i: usize = 0;
    while (i < HIDDEN) : (i += 2 * LANES) {
        inline for (&sums, 0..) |*sum, k| {
            const a: V16 = acc[i + k * LANES ..][0..LANES].*;
            const c = @min(@max(a, zero), qa);
            const ww: V16 = w[i + k * LANES ..][0..LANES].*;
            // c * w fits in i16 because c <= QA and |w| <= 1.98 * QB (lizard SCReLU trick).
            const cw = c *% ww;
            sum.* +%= @as(V32, c) *% @as(V32, cw);
        }
    }
    return sums[0] +% sums[1];
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
    for (&net.ft_w) |*x| x.* = r.intRangeAtMost(FtW, -60, 60);
    for (&net.ft_b) |*x| x.* = r.intRangeAtMost(i16, -60, 60);
    for (&net.out_w) |*bk| for (bk) |*x| {
        x.* = r.intRangeAtMost(i16, -127, 127);
    };
    for (&net.out_b) |*x| x.* = r.intRangeAtMost(i16, -1000, 1000);

    var pos = try Position.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    var acc: Accumulator = undefined;
    refresh(net, &acc, &pos);
    var cache: Cache = undefined;
    cache.reset(net);
    for (0..200) |_| {
        var list = movegen.MoveList{};
        movegen.generate(&pos, &list, .all);
        if (list.len == 0) break;
        const m = list.moves[r.uintLessThan(usize, list.len)];
        const child = pos.makeMove(m);
        var inc: Accumulator = undefined;
        update(net, &cache, &acc, &inc, &child);
        var fresh: Accumulator = undefined;
        refresh(net, &fresh, &child);
        try std.testing.expectEqualSlices(i16, &fresh.v[0], &inc.v[0]);
        try std.testing.expectEqualSlices(i16, &fresh.v[1], &inc.v[1]);
        pos = child;
        acc = inc;
    }
}

test "king buckets: mirrored positions evaluate the same" {
    if (!MIRROR) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const net = try gpa.create(Network);
    defer gpa.destroy(net);
    var prng = std.Random.DefaultPrng.init(2);
    const r = prng.random();
    for (&net.ft_w) |*x| x.* = r.intRangeAtMost(FtW, -60, 60);
    for (&net.ft_b) |*x| x.* = r.intRangeAtMost(i16, -60, 60);
    for (&net.out_w) |*bk| for (bk) |*x| {
        x.* = r.intRangeAtMost(i16, -127, 127);
    };
    for (&net.out_b) |*x| x.* = r.intRangeAtMost(i16, -1000, 1000);

    const fens = [_][]const u8{
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w - - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 b - - 0 1",
        "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1",
    };
    for (fens) |fen| {
        const pos = try Position.fromFen(fen);
        var mirrored = Position{ .side = pos.side };
        var occ = pos.occupied();
        while (occ != 0) {
            const sq = bb.popLsb(&occ);
            mirrored.addPiece(pos.board[sq], sq ^ 7);
        }
        try std.testing.expectEqual(evaluateFresh(net, &pos), evaluateFresh(net, &mirrored));
    }
}

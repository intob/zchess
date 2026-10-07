//! Attack tables. Leaper tables are built at compile time; slider tables use
//! magic bitboards that are found at startup with a fixed seed (a few ms).
//! (PEXT would be faster on x86, but Apple Silicon has no equivalent.)

const bb = @import("bitboard.zig");
const Square = bb.Square;

const knight_deltas = [_][2]i8{ .{ 1, 2 }, .{ 2, 1 }, .{ 2, -1 }, .{ 1, -2 }, .{ -1, -2 }, .{ -2, -1 }, .{ -2, 1 }, .{ -1, 2 } };
const king_deltas = [_][2]i8{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ -1, 1 }, .{ -1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 } };
const rook_dirs = [_][2]i8{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
const bishop_dirs = [_][2]i8{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } };

fn leaper(sq: usize, deltas: []const [2]i8) u64 {
    var r: u64 = 0;
    const f: i32 = @intCast(sq & 7);
    const rk: i32 = @intCast(sq >> 3);
    for (deltas) |d| {
        const nf = f + d[0];
        const nr = rk + d[1];
        if (nf >= 0 and nf < 8 and nr >= 0 and nr < 8) r |= @as(u64, 1) << @intCast(nr * 8 + nf);
    }
    return r;
}

fn slidingAttacks(sq: usize, occ: u64, dirs: []const [2]i8) u64 {
    var r: u64 = 0;
    for (dirs) |d| {
        var f: i32 = @intCast(sq & 7);
        var rk: i32 = @intCast(sq >> 3);
        while (true) {
            f += d[0];
            rk += d[1];
            if (f < 0 or f >= 8 or rk < 0 or rk >= 8) break;
            const b = @as(u64, 1) << @intCast(rk * 8 + f);
            r |= b;
            if (occ & b != 0) break;
        }
    }
    return r;
}

pub const knight: [64]u64 = blk: {
    var t: [64]u64 = undefined;
    for (0..64) |s| t[s] = leaper(s, &knight_deltas);
    break :blk t;
};

pub const king: [64]u64 = blk: {
    var t: [64]u64 = undefined;
    for (0..64) |s| t[s] = leaper(s, &king_deltas);
    break :blk t;
};

/// pawn[color][sq]: squares attacked by a pawn of `color` standing on `sq`.
pub const pawn: [2][64]u64 = blk: {
    var t: [2][64]u64 = undefined;
    for (0..64) |s| {
        t[0][s] = leaper(s, &.{ .{ -1, 1 }, .{ 1, 1 } });
        t[1][s] = leaper(s, &.{ .{ -1, -1 }, .{ 1, -1 } });
    }
    break :blk t;
};

pub const Magic = struct {
    mask: u64,
    magic: u64,
    table: [*]const u64,
    shift: u6,
};

pub var rook_magics: [64]Magic = undefined;
pub var bishop_magics: [64]Magic = undefined;
var slider_table: [102400 + 5248]u64 = undefined;

/// between[a][b]: squares strictly between a and b if aligned, else 0.
pub var between: [64][64]u64 = undefined;
/// line[a][b]: the full line through a and b if aligned, else 0.
pub var line: [64][64]u64 = undefined;

pub inline fn rook(sq: Square, occ: u64) u64 {
    const m = &rook_magics[sq];
    return m.table[@intCast(((occ & m.mask) *% m.magic) >> m.shift)];
}

pub inline fn bishop(sq: Square, occ: u64) u64 {
    const m = &bishop_magics[sq];
    return m.table[@intCast(((occ & m.mask) *% m.magic) >> m.shift)];
}

pub inline fn queen(sq: Square, occ: u64) u64 {
    return rook(sq, occ) | bishop(sq, occ);
}

var initialized = false;

pub fn init() void {
    if (initialized) return;
    initialized = true;
    var rng = Rng{ .s = 0x9E3779B97F4A7C15 };
    var offset: usize = 0;
    initMagics(&rook_magics, &rook_dirs, &rook_magic_numbers, &offset, &rng);
    initMagics(&bishop_magics, &bishop_dirs, &bishop_magic_numbers, &offset, &rng);

    for (0..64) |a| {
        for (0..64) |b| {
            between[a][b] = 0;
            line[a][b] = 0;
            if (a == b) continue;
            const sa: Square = @intCast(a);
            const sb: Square = @intCast(b);
            const ba = bb.bit(sa);
            const bbb = bb.bit(sb);
            if (rook(sa, 0) & bbb != 0) {
                line[a][b] = (rook(sa, 0) & rook(sb, 0)) | ba | bbb;
                between[a][b] = rook(sa, bbb) & rook(sb, ba);
            } else if (bishop(sa, 0) & bbb != 0) {
                line[a][b] = (bishop(sa, 0) & bishop(sb, 0)) | ba | bbb;
                between[a][b] = bishop(sa, bbb) & bishop(sb, ba);
            }
        }
    }
}

// Found with `zchess dump-magics` (random search, seed above), cached to skip
// the ~1s search at startup.
const rook_magic_numbers = [64]u64{
    0x1080004008801020,
    0x0840092002c03000,
    0x1900200010400900,
    0x0880100008000480,
    0x4200100420080200,
    0x8100020100080400,
    0x0200040110886200,
    0x0200008040220411,
    0x0404800084400220,
    0x0000401000402000,
    0x0086001081220440,
    0x0408800800100280,
    0x000a001201040820,
    0x8848800200840080,
    0x4001000100040200,
    0x0442000102105084,
    0x9080010020804100,
    0x0040404000201009,
    0x0000808010002009,
    0x2200090021d00100,
    0x0008008008040080,
    0x0004004002010040,
    0x0011040008015042,
    0x00000a0001768104,
    0x0000800080204009,
    0x2010004140002001,
    0x9800200280100080,
    0x1000100080080080,
    0x0442000a00049020,
    0x2100040080020080,
    0x0800120400900148,
    0x0010040a00128541,
    0x2800804000800030,
    0x1010002000400041,
    0x4000200011004100,
    0x0610008410800800,
    0x0400802402800800,
    0xc100020080800400,
    0x0002000802000401,
    0x0182085882000401,
    0x0220204000808000,
    0x2860100040024022,
    0x0001002004110040,
    0x99101042000a0020,
    0x0004080004008080,
    0x0010040002008080,
    0x2012004881020004,
    0x8300842444820011,
    0x0088403882010200,
    0x0820400080210100,
    0x0110910040a00300,
    0x0801100280080480,
    0x0242009008200600,
    0x1002000489500200,
    0x0040800200010080,
    0x0091800041000080,
    0x0000209300488001,
    0x04c1002414824001,
    0x020020000b001041,
    0x7000100004200901,
    0x8002002004100802,
    0x30010002084c0007,
    0x0888221800813004,
    0x4000002840840112,
};
const bishop_magic_numbers = [64]u64{
    0xa010041108003100,
    0x006082020a002900,
    0x6810010619200000,
    0x08281a0520000408,
    0x0001104001000400,
    0x0018901008048400,
    0x00040a0210245280,
    0x000200210808a402,
    0x9140048410821200,
    0x0800091010820041,
    0x20504804832202c0,
    0x0100091401081000,
    0x8021011140000012,
    0x0810020804450400,
    0x208b0542109008a2,
    0x0080084a08040204,
    0x0040e2a80811244c,
    0x2505022008008108,
    0x0430220100420040,
    0x010a040420220040,
    0x1105000290400000,
    0x0093001200822120,
    0x4000a62048043004,
    0x280120048a015004,
    0x006090002a020814,
    0x44042000240800d0,
    0x01102800040a4400,
    0x1004080080220040,
    0x0001001011004024,
    0x0010044000805040,
    0x0914041200820100,
    0x0004821012821480,
    0x0024040500c05021,
    0x0088611002080200,
    0x0116080a00040020,
    0x4000020080080080,
    0x2450450140840040,
    0x0000880201484100,
    0x0222020404020092,
    0x8081110600002e00,
    0x2842101105000801,
    0x1100809008001025,
    0x00020202221c0400,
    0x0422014022009020,
    0x0210046102100c00,
    0xc004008082029102,
    0x00aa461801101200,
    0x0404080080201108,
    0x020542108c205002,
    0x0410544804100100,
    0x0040910841100000,
    0x0400200042021100,
    0x00004204850400c0,
    0x0200100410a42102,
    0x1040020801210102,
    0x0805040410420000,
    0x2884804130100200,
    0x800c262201242000,
    0x1058000194108800,
    0x0014221054420204,
    0x0104000012a02200,
    0x0200881003300100,
    0x0140400202840100,
    0x0402020801010201,
};

const Rng = struct {
    s: u64,
    fn next(self: *Rng) u64 {
        self.s ^= self.s >> 12;
        self.s ^= self.s << 25;
        self.s ^= self.s >> 27;
        return self.s *% 2685821657736338717;
    }
};

fn initMagics(magics: *[64]Magic, dirs: []const [2]i8, known: *const [64]u64, offset: *usize, rng: *Rng) void {
    var occupancy: [4096]u64 = undefined;
    var reference: [4096]u64 = undefined;
    var epoch = [_]u32{0} ** 4096;
    var cnt: u32 = 0;

    for (0..64) |sq| {
        const s: Square = @intCast(sq);
        const rank_bb = bb.RANK_1 << (@as(u6, bb.rankOf(s)) * 8);
        const file_bb = bb.FILE_A << bb.fileOf(s);
        const edges = ((bb.RANK_1 | bb.RANK_8) & ~rank_bb) | ((bb.FILE_A | bb.FILE_H) & ~file_bb);
        const mask = slidingAttacks(sq, 0, dirs) & ~edges;
        const bits = bb.popcount(mask);
        const size = @as(usize, 1) << @intCast(bits);
        const table = slider_table[offset.*..][0..size];

        var n: usize = 0;
        var sub: u64 = 0;
        while (true) {
            occupancy[n] = sub;
            reference[n] = slidingAttacks(sq, sub, dirs);
            n += 1;
            sub = (sub -% mask) & mask;
            if (sub == 0) break;
        }

        const shift: u6 = @intCast(64 - bits);
        var first = true;
        while (true) {
            // Try the precomputed magic first; fall back to a random search.
            const magic = if (first) known[sq] else rng.next() & rng.next() & rng.next();
            first = false;
            if (bb.popcount((mask *% magic) >> 56) < 6) continue;
            cnt += 1;
            var ok = true;
            for (0..n) |i| {
                const idx: usize = @intCast((occupancy[i] *% magic) >> shift);
                if (epoch[idx] < cnt) {
                    epoch[idx] = cnt;
                    table[idx] = reference[i];
                } else if (table[idx] != reference[i]) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                magics[sq] = .{ .mask = mask, .magic = magic, .table = table.ptr, .shift = shift };
                break;
            }
        }
        offset.* += size;
    }
}

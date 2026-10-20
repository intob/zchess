//! Lock-free transposition table. Each entry stores key ^ data so that torn
//! writes from concurrent threads are detected and treated as a miss. Entries
//! come in clusters of 4 (one 64-byte cache line): a position is looked for in
//! its cluster, and a new one replaces the cluster's least useful entry (see
//! `store`), so deep and recent results outlive shallow old ones.

const std = @import("std");
const Move = @import("position.zig").Move;

pub const Bound = enum(u2) { none = 0, upper = 1, lower = 2, exact = 3 };

pub const Data = packed struct(u64) {
    move: u16,
    score: i16,
    eval: i16,
    depth: u8,
    bound: Bound,
    age: u6,
};

const Entry = struct {
    key: u64,
    data: u64,
};

const CLUSTER = 4;

pub const TT = struct {
    /// CLUSTER entries per cluster, clusters aligned to cache lines.
    entries: []align(64) Entry,
    age: u6 = 0,

    pub fn init(gpa: std.mem.Allocator, mb: usize) !TT {
        const clusters = @max(1, mb * 1024 * 1024 / (CLUSTER * @sizeOf(Entry)));
        const entries = try gpa.alignedAlloc(Entry, .@"64", clusters * CLUSTER);
        var t = TT{ .entries = entries };
        t.clear();
        return t;
    }

    pub fn deinit(t: *TT, gpa: std.mem.Allocator) void {
        gpa.free(t.entries);
    }

    pub fn clear(t: *TT) void {
        @memset(t.entries, .{ .key = 0, .data = 0 });
        t.age = 0;
    }

    pub fn newSearch(t: *TT) void {
        t.age +%= 1;
    }

    /// The first entry of `key`'s cluster.
    inline fn cluster(t: *const TT, key: u64) []Entry {
        const n_clusters = t.entries.len / CLUSTER;
        const c: usize = @intCast((@as(u128, key) * n_clusters) >> 64);
        return t.entries[c * CLUSTER ..][0..CLUSTER];
    }

    pub inline fn prefetch(t: *const TT, key: u64) void {
        @prefetch(t.cluster(key).ptr, .{});
    }

    pub inline fn probe(t: *const TT, key: u64) ?Data {
        for (t.cluster(key)) |*e| {
            const d = @atomicLoad(u64, &e.data, .monotonic);
            const k = @atomicLoad(u64, &e.key, .monotonic);
            if (k ^ d == key and d != 0) return @bitCast(d);
        }
        return null;
    }

    /// How much an entry is worth keeping: its depth, less 8 per search
    /// since it was written (an empty entry is worth nothing).
    inline fn worth(t: *const TT, d: u64) i32 {
        if (d == 0) return std.math.minInt(i32);
        const data: Data = @bitCast(d);
        const age_gap: i32 = @as(u6, t.age -% data.age);
        return @as(i32, data.depth) - 8 * age_gap;
    }

    pub inline fn store(t: *TT, key: u64, move: Move, score: i32, eval: i32, depth: i32, bound: Bound) void {
        // This position's entry if the cluster has it, else the least worth keeping.
        const c = t.cluster(key);
        var e = &c[0];
        var e_worth: i32 = std.math.maxInt(i32);
        var same = false;
        for (c) |*x| {
            const xd = @atomicLoad(u64, &x.data, .monotonic);
            const xk = @atomicLoad(u64, &x.key, .monotonic);
            if (xk ^ xd == key and xd != 0) {
                e = x;
                same = true;
                break;
            }
            const w = t.worth(xd);
            if (w < e_worth) {
                e = x;
                e_worth = w;
            }
        }
        const old_d = @atomicLoad(u64, &e.data, .monotonic);
        const old: Data = @bitCast(old_d);
        const d: i32 = @max(depth, 0);
        if (!same or bound == .exact or d + 4 > old.depth or old.age != t.age) {
            const new = Data{
                .move = if (move.data == 0 and same) old.move else move.data,
                .score = @intCast(score),
                .eval = @intCast(eval),
                .depth = @intCast(@min(d, 255)),
                .bound = bound,
                .age = t.age,
            };
            const nd: u64 = @bitCast(new);
            @atomicStore(u64, &e.data, nd, .monotonic);
            @atomicStore(u64, &e.key, key ^ nd, .monotonic);
        }
    }

    /// Per-mille of sampled entries written during the current search.
    pub fn hashfull(t: *const TT) u32 {
        var n: u32 = 0;
        const sample = @min(t.entries.len, 1000);
        for (t.entries[0..sample]) |e| {
            const d: Data = @bitCast(e.data);
            if (e.data != 0 and d.age == t.age) n += 1;
        }
        return @intCast(n * 1000 / sample);
    }
};

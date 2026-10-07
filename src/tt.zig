//! Lock-free transposition table. Each entry stores key ^ data so that torn
//! writes from concurrent threads are detected and treated as a miss.

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

pub const TT = struct {
    entries: []Entry,
    age: u6 = 0,

    pub fn init(gpa: std.mem.Allocator, mb: usize) !TT {
        const n = @max(1, mb * 1024 * 1024 / @sizeOf(Entry));
        const entries = try gpa.alloc(Entry, n);
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

    inline fn index(t: *const TT, key: u64) usize {
        return @intCast((@as(u128, key) * t.entries.len) >> 64);
    }

    pub inline fn prefetch(t: *const TT, key: u64) void {
        @prefetch(&t.entries[t.index(key)], .{});
    }

    pub inline fn probe(t: *const TT, key: u64) ?Data {
        const e = &t.entries[t.index(key)];
        const d = @atomicLoad(u64, &e.data, .monotonic);
        const k = @atomicLoad(u64, &e.key, .monotonic);
        if (k ^ d != key or d == 0) return null;
        return @bitCast(d);
    }

    pub inline fn store(t: *TT, key: u64, move: Move, score: i32, eval: i32, depth: i32, bound: Bound) void {
        const e = &t.entries[t.index(key)];
        const old_d = @atomicLoad(u64, &e.data, .monotonic);
        const old_k = @atomicLoad(u64, &e.key, .monotonic);
        const old: Data = @bitCast(old_d);
        const same = old_k ^ old_d == key;
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

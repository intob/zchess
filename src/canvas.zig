//! Minimal RGB canvas with a 5x7 bitmap font and a PNG encoder
//! (zlib via std.compress.flate). Shared by `art` and `viz`.

const std = @import("std");
const Io = std.Io;

pub const Rgb = [3]u8;

pub fn hsv(h: f32, s: f32, v: f32) Rgb {
    const hh = @mod(h, 1.0) * 6.0;
    const c = v * s;
    const x = c * (1 - @abs(@mod(hh, 2.0) - 1));
    const m = v - c;
    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(hh))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    var out: Rgb = undefined;
    for (0..3) |i| out[i] = @intFromFloat(@round((rgb[i] + m) * 255));
    return out;
}

pub fn lerp(a: Rgb, b: Rgb, t: f32) Rgb {
    var out: Rgb = undefined;
    const tc = std.math.clamp(t, 0, 1);
    for (0..3) |i| {
        const av: f32 = @floatFromInt(a[i]);
        const bv: f32 = @floatFromInt(b[i]);
        out[i] = @intFromFloat(@round(av + (bv - av) * tc));
    }
    return out;
}

pub const Canvas = struct {
    w: usize,
    h: usize,
    px: []u8,

    pub fn init(gpa: std.mem.Allocator, w: usize, h: usize, bg: Rgb) !Canvas {
        var c = Canvas{ .w = w, .h = h, .px = try gpa.alloc(u8, w * h * 3) };
        c.rect(0, 0, w, h, bg);
        return c;
    }

    pub fn deinit(c: *Canvas, gpa: std.mem.Allocator) void {
        gpa.free(c.px);
    }

    pub inline fn set(c: *Canvas, x: usize, y: usize, col: Rgb) void {
        if (x >= c.w or y >= c.h) return;
        const i = (y * c.w + x) * 3;
        @memcpy(c.px[i..][0..3], &col);
    }

    /// Additive blend of `col * a` into the pixel at integer coordinates.
    pub inline fn add(c: *Canvas, x: isize, y: isize, col: Rgb, a: f32) void {
        if (x < 0 or y < 0 or x >= c.w or y >= c.h) return;
        const i = (@as(usize, @intCast(y)) * c.w + @as(usize, @intCast(x))) * 3;
        for (0..3) |k| {
            const v = @as(f32, @floatFromInt(c.px[i + k])) + @as(f32, @floatFromInt(col[k])) * a;
            c.px[i + k] = @intFromFloat(@min(v, 255));
        }
    }

    /// Additive blend at a sub-pixel position, spread bilinearly over 4 pixels.
    pub fn splat(c: *Canvas, x: f32, y: f32, col: Rgb, a: f32) void {
        const x0 = @floor(x);
        const y0 = @floor(y);
        const fx = x - x0;
        const fy = y - y0;
        const ix: isize = @intFromFloat(x0);
        const iy: isize = @intFromFloat(y0);
        c.add(ix, iy, col, a * (1 - fx) * (1 - fy));
        c.add(ix + 1, iy, col, a * fx * (1 - fy));
        c.add(ix, iy + 1, col, a * (1 - fx) * fy);
        c.add(ix + 1, iy + 1, col, a * fx * fy);
    }

    /// Soft gaussian glow centred at (x, y).
    pub fn glow(c: *Canvas, x: f32, y: f32, radius: f32, col: Rgb, a: f32) void {
        const reach: isize = @intFromFloat(@ceil(radius * 3));
        const ix: isize = @intFromFloat(@round(x));
        const iy: isize = @intFromFloat(@round(y));
        const s2 = 2 * radius * radius;
        var dy: isize = -reach;
        while (dy <= reach) : (dy += 1) {
            var dx: isize = -reach;
            while (dx <= reach) : (dx += 1) {
                const px = @as(f32, @floatFromInt(ix + dx)) - x;
                const py = @as(f32, @floatFromInt(iy + dy)) - y;
                c.add(ix + dx, iy + dy, col, a * @exp(-(px * px + py * py) / s2));
            }
        }
    }

    /// Quadratic Bezier curve drawn additively.
    pub fn curve(c: *Canvas, p0: [2]f32, p1: [2]f32, p2: [2]f32, col: Rgb, a: f32) void {
        const len = @abs(p2[0] - p0[0]) + @abs(p2[1] - p0[1]) + @abs(p1[0] - p0[0]) + @abs(p1[1] - p0[1]);
        const steps: usize = @intFromFloat(@max(len, 8));
        for (0..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const u = 1 - t;
            const x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0];
            const y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1];
            c.splat(x, y, col, a);
        }
    }

    pub fn rect(c: *Canvas, x0: usize, y0: usize, w: usize, h: usize, col: Rgb) void {
        for (y0..y0 + h) |y| for (x0..x0 + w) |x| c.set(x, y, col);
    }

    pub fn textWidth(s: []const u8, scale: usize) usize {
        if (s.len == 0) return 0;
        return s.len * 6 * scale - scale;
    }

    /// Draws `s` (rendered upper-case) with its top-left corner at (x, y).
    pub fn text(c: *Canvas, x: usize, y: usize, s: []const u8, scale: usize, col: Rgb) void {
        for (s, 0..) |ch, i| {
            const g = glyphs[std.ascii.toUpper(ch) & 0x7F];
            for (0..7) |gy| for (0..5) |gx| {
                const bit: u6 = @intCast(34 - (gy * 5 + gx));
                if ((g >> bit) & 1 == 1) c.rect(x + i * 6 * scale + gx * scale, y + gy * scale, scale, scale, col);
            };
        }
    }

    pub fn writePng(c: *const Canvas, gpa: std.mem.Allocator, w: *Io.Writer) !void {
        const stride = c.w * 3;
        const raw = try gpa.alloc(u8, c.h * (stride + 1));
        defer gpa.free(raw);
        for (0..c.h) |y| {
            raw[y * (stride + 1)] = 0; // filter: none
            @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], c.px[y * stride ..][0..stride]);
        }

        var z: Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
        defer z.deinit();
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var comp = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .default);
        try comp.writer.writeAll(raw);
        try comp.finish();

        try w.writeAll("\x89PNG\r\n\x1a\n");
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], @intCast(c.w), .big);
        std.mem.writeInt(u32, ihdr[4..8], @intCast(c.h), .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 2; // truecolour RGB
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try writeChunk(w, "IHDR", &ihdr);
        try writeChunk(w, "IDAT", z.written());
        try writeChunk(w, "IEND", "");
    }

    pub fn savePng(c: *const Canvas, gpa: std.mem.Allocator, io: Io, path: []const u8) !void {
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var fw = f.writer(io, &buf);
        try c.writePng(gpa, &fw.interface);
        try fw.interface.flush();
    }
};

fn writeChunk(w: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try w.writeAll(&len);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var cs: [4]u8 = undefined;
    std.mem.writeInt(u32, &cs, crc.final(), .big);
    try w.writeAll(&cs);
}

const Glyph = struct { ch: u8, rows: [7]*const [5]u8 };

// zig fmt: off
const font_src = [_]Glyph{
    .{ .ch = 'A', .rows = .{ ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" } },
    .{ .ch = 'B', .rows = .{ "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####." } },
    .{ .ch = 'C', .rows = .{ ".###.", "#...#", "#....", "#....", "#....", "#...#", ".###." } },
    .{ .ch = 'D', .rows = .{ "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####." } },
    .{ .ch = 'E', .rows = .{ "#####", "#....", "#....", "####.", "#....", "#....", "#####" } },
    .{ .ch = 'F', .rows = .{ "#####", "#....", "#....", "####.", "#....", "#....", "#...." } },
    .{ .ch = 'G', .rows = .{ ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####" } },
    .{ .ch = 'H', .rows = .{ "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" } },
    .{ .ch = 'I', .rows = .{ ".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###." } },
    .{ .ch = 'J', .rows = .{ "..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.." } },
    .{ .ch = 'K', .rows = .{ "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" } },
    .{ .ch = 'L', .rows = .{ "#....", "#....", "#....", "#....", "#....", "#....", "#####" } },
    .{ .ch = 'M', .rows = .{ "#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#" } },
    .{ .ch = 'N', .rows = .{ "#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#" } },
    .{ .ch = 'O', .rows = .{ ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." } },
    .{ .ch = 'P', .rows = .{ "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." } },
    .{ .ch = 'Q', .rows = .{ ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#" } },
    .{ .ch = 'R', .rows = .{ "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" } },
    .{ .ch = 'S', .rows = .{ ".####", "#....", "#....", ".###.", "....#", "....#", "####." } },
    .{ .ch = 'T', .rows = .{ "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." } },
    .{ .ch = 'U', .rows = .{ "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." } },
    .{ .ch = 'V', .rows = .{ "#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.." } },
    .{ .ch = 'W', .rows = .{ "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#." } },
    .{ .ch = 'X', .rows = .{ "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#" } },
    .{ .ch = 'Y', .rows = .{ "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.." } },
    .{ .ch = 'Z', .rows = .{ "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####" } },
    .{ .ch = '0', .rows = .{ ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###." } },
    .{ .ch = '1', .rows = .{ "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###." } },
    .{ .ch = '2', .rows = .{ ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####" } },
    .{ .ch = '3', .rows = .{ "#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###." } },
    .{ .ch = '4', .rows = .{ "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#." } },
    .{ .ch = '5', .rows = .{ "#####", "#....", "####.", "....#", "....#", "#...#", ".###." } },
    .{ .ch = '6', .rows = .{ "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###." } },
    .{ .ch = '7', .rows = .{ "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..." } },
    .{ .ch = '8', .rows = .{ ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###." } },
    .{ .ch = '9', .rows = .{ ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.." } },
    .{ .ch = '.', .rows = .{ ".....", ".....", ".....", ".....", ".....", ".##..", ".##.." } },
    .{ .ch = ',', .rows = .{ ".....", ".....", ".....", ".....", ".##..", "..#..", ".#..." } },
    .{ .ch = '-', .rows = .{ ".....", ".....", ".....", ".###.", ".....", ".....", "....." } },
    .{ .ch = '+', .rows = .{ ".....", "..#..", "..#..", "#####", "..#..", "..#..", "....." } },
    .{ .ch = '=', .rows = .{ ".....", ".....", "#####", ".....", "#####", ".....", "....." } },
    .{ .ch = ':', .rows = .{ ".....", ".##..", ".##..", ".....", ".##..", ".##..", "....." } },
    .{ .ch = '(', .rows = .{ "...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#." } },
    .{ .ch = ')', .rows = .{ ".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..." } },
    .{ .ch = '/', .rows = .{ "....#", "....#", "...#.", "..#..", ".#...", "#....", "#...." } },
    .{ .ch = '%', .rows = .{ "##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##" } },
    .{ .ch = '>', .rows = .{ ".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..." } },
    .{ .ch = '<', .rows = .{ "...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#." } },
};
// zig fmt: on

/// glyphs[ascii] = 35-bit bitmap, row-major, most significant bit first.
const glyphs: [128]u35 = blk: {
    @setEvalBranchQuota(20000);
    var t = [_]u35{0} ** 128;
    for (font_src) |g| {
        var bits: u35 = 0;
        for (g.rows) |r| for (r) |c| {
            bits = (bits << 1) | @intFromBool(c == '#');
        };
        t[g.ch] = bits;
    }
    break :blk t;
};

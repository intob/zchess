//! Build fingerprint art: hash a file (normally the zchess binary itself),
//! use the hash to seed a short game the engine plays against itself, and
//! render the final position as a pixel-art PNG in a hash-derived palette.
//! The same binary always produces the same picture.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const search = @import("search.zig");
const game = @import("game.zig");
const cli = @import("cli.zig");
const TT = @import("tt.zig").TT;
const Output = @import("output.zig").Output;
const canvas = @import("canvas.zig");

const Position = position.Position;
const Move = position.Move;

// 16x16 sprites: 'o' outline, 'x' fill, anything else transparent.
pub const sprites = [6][16]*const [16]u8{
    .{ // pawn
        "................",
        "................",
        "................",
        "......oooo......",
        ".....oxxxxo.....",
        ".....oxxxxo.....",
        ".....oxxxxo.....",
        "......oxxo......",
        ".....oxxxxo.....",
        "....oxxxxxxo....",
        ".....oxxxxo.....",
        ".....oxxxxo.....",
        "....oxxxxxxo....",
        "...oxxxxxxxxo...",
        "...oooooooooo...",
        "................",
    },
    .{ // knight
        "................",
        "......o.o.......",
        ".....oxoxo......",
        "....oxxxxxo.....",
        "...oxxoxxxxo....",
        "..oxxxxxxxxxo...",
        "..oxxxxxxxxxxo..",
        "...oooxoxxxxxo..",
        ".....ooxxxxxxo..",
        "....oxxxxxxxo...",
        "....oxxxxxxxo...",
        "...oxxxxxxxxxo..",
        "...oxxxxxxxxxo..",
        "..oxxxxxxxxxxxo.",
        "..ooooooooooooo.",
        "................",
    },
    .{ // bishop
        "................",
        ".......oo.......",
        "......oxxo......",
        ".....oxxoxo.....",
        "....oxxoxxxo....",
        "....oxoxxxxo....",
        "....oxxxxxxo....",
        ".....oxxxxo.....",
        "......oxxo......",
        ".....oxxxxo.....",
        ".....oxxxxo.....",
        "....oxxxxxxo....",
        "...oxxxxxxxxo...",
        "..oxxxxxxxxxxo..",
        "..oooooooooooo..",
        "................",
    },
    .{ // rook
        "................",
        "................",
        "..ooo.oooo.ooo..",
        "..oxooxxxxooxo..",
        "..oxxxxxxxxxxo..",
        "..oooxxxxxxooo..",
        "....oxxxxxxo....",
        "....oxxxxxxo....",
        "....oxxxxxxo....",
        "....oxxxxxxo....",
        "....oxxxxxxo....",
        "...oooxxxxooo...",
        "..oxxxxxxxxxxo..",
        "..oxxxxxxxxxxo..",
        "..oooooooooooo..",
        "................",
    },
    .{ // queen
        "................",
        "..o...o..o...o..",
        ".oxo.oxooxo.oxo.",
        "..oxooxxxxooxo..",
        "..oxxxxxxxxxxo..",
        "...oxxxxxxxxo...",
        "....oxxxxxxo....",
        "....oxxxxxxo....",
        ".....oxxxxo.....",
        ".....oxxxxo.....",
        "....oxxxxxxo....",
        "...oxxxxxxxxo...",
        "..oxxxxxxxxxxo..",
        "..oxxxxxxxxxxo..",
        "..oooooooooooo..",
        "................",
    },
    .{ // king
        ".......oo.......",
        "......oxxo......",
        ".....ooxxoo.....",
        ".....oxxxxo.....",
        ".....ooxxoo.....",
        "..ooo.oxxo.ooo..",
        ".oxxxooxxooxxxo.",
        ".oxxxxxxxxxxxxo.",
        ".oxxxxxxxxxxxxo.",
        "..oxxxxxxxxxxo..",
        "...oxxxxxxxxo...",
        "....oxxxxxxo....",
        "...oxxxxxxxxo...",
        "..oxxxxxxxxxxo..",
        "..oooooooooooo..",
        "................",
    },
};

// 3x5 font for hex digits, one u15 per glyph, rows top to bottom.
const font = [16]u15{
    0b111_101_101_101_111, 0b010_110_010_010_111, 0b111_001_111_100_111, 0b111_001_111_001_111,
    0b101_101_111_001_001, 0b111_100_111_001_111, 0b111_100_111_101_111, 0b111_001_001_001_001,
    0b111_101_111_101_111, 0b111_101_111_001_111, 0b111_101_111_101_101, 0b110_101_110_101_110,
    0b111_100_100_100_111, 0b110_101_101_101_110, 0b111_100_111_100_111, 0b111_100_111_100_100,
};

const SPRITE_SCALE = 4;
const SQ = 16 * SPRITE_SCALE;
const MARGIN = 32;
const BOARD = 8 * SQ;
const TEXT_SCALE = 4;
const W = BOARD + 2 * MARGIN;
const H = MARGIN + BOARD + 24 + 5 * TEXT_SCALE + 28;

const Rgb = canvas.Rgb;
const hsv = canvas.hsv;
const Image = canvas.Canvas;

const Palette = struct {
    bg: Rgb,
    light: Rgb,
    dark: Rgb,
    light_hl: Rgb,
    dark_hl: Rgb,
    text: Rgb,

    fn fromHash(h: [32]u8) Palette {
        const hue = @as(f32, @floatFromInt(std.mem.readInt(u16, h[8..10], .little))) / 65536.0;
        const accent = hue + 0.33 + @as(f32, @floatFromInt(h[10])) / 255.0 * 0.34;
        return .{
            .bg = hsv(hue, 0.35, 0.16),
            .light = hsv(hue, 0.22, 0.90),
            .dark = hsv(hue, 0.42, 0.60),
            .light_hl = hsv(accent, 0.35, 0.92),
            .dark_hl = hsv(accent, 0.50, 0.68),
            .text = hsv(hue, 0.25, 0.80),
        };
    }
};

/// The game the binary "dreams": a hash-seeded opening, then engine self-play.
fn dreamGame(gpa: std.mem.Allocator, io: Io, h: [32]u8) !struct { pos: Position, last: Move } {
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, h[0..8], .little));
    const rng = prng.random();
    var pos = game.randomOpening(rng, 4 + rng.uintLessThan(usize, 4)) orelse Position.startpos();
    var last = Move.none;

    const net = try cli.loadNet(gpa, io, "");
    var tt = try TT.init(gpa, 4);
    defer tt.deinit(gpa);
    var stop = std.atomic.Value(bool).init(false);
    const s = try search.Searcher.create(gpa, io, &tt, net, &stop);
    defer gpa.destroy(s);

    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(gpa);
    const plies = 16 + rng.uintLessThan(usize, 33);
    for (0..plies) |_| {
        if (game.terminal(&pos, keys.items) != null) break;
        s.setPosition(&pos, keys.items);
        const r = s.search(.{ .soft_nodes = 1500, .nodes = 20000 });
        try keys.append(gpa, pos.key);
        pos = pos.makeMove(r.move);
        last = r.move;
    }
    return .{ .pos = pos, .last = last };
}

fn render(img: *Image, pos: *const Position, last: Move, h: [32]u8) void {
    const pal = Palette.fromHash(h);
    img.rect(0, 0, W, H, pal.bg);

    for (0..64) |i| {
        const sq: bb.Square = @intCast(i);
        const file: usize = bb.fileOf(sq);
        const rank: usize = bb.rankOf(sq);
        const x0 = MARGIN + file * SQ;
        const y0 = MARGIN + (7 - rank) * SQ;
        const light = (file + rank) % 2 == 1;
        const hl = last.data != 0 and (sq == last.from() or sq == last.to());
        img.rect(x0, y0, SQ, SQ, if (hl) (if (light) pal.light_hl else pal.dark_hl) else (if (light) pal.light else pal.dark));

        const pc = pos.board[sq];
        if (pc == bb.NO_PIECE) continue;
        const fill: Rgb = if (bb.pieceColor(pc) == bb.WHITE) .{ 0xF6, 0xF2, 0xE8 } else .{ 0x2B, 0x29, 0x2E };
        const outline: Rgb = .{ 0x12, 0x11, 0x14 };
        const sprite = sprites[bb.pieceType(pc)];
        for (0..16) |sy| for (0..16) |sx| {
            const c: ?Rgb = switch (sprite[sy][sx]) {
                'o' => outline,
                'x' => fill,
                else => null,
            };
            if (c) |col| img.rect(x0 + sx * SPRITE_SCALE, y0 + sy * SPRITE_SCALE, SPRITE_SCALE, SPRITE_SCALE, col);
        };
    }

    // First 16 hex digits of the hash, centred under the board.
    const chars = 16;
    const advance = 4 * TEXT_SCALE;
    const text_w = chars * advance - TEXT_SCALE;
    const tx = (W - text_w) / 2;
    const ty = MARGIN + BOARD + 24;
    for (0..chars) |i| {
        const nib_shift: u3 = if (i % 2 == 0) 4 else 0;
        const nibble = (h[i / 2] >> nib_shift) & 0xF;
        const g = font[nibble];
        for (0..5) |gy| for (0..3) |gx| {
            const shift: u4 = @intCast(14 - (gy * 3 + gx));
            if ((g >> shift) & 1 == 1)
                img.rect(tx + i * advance + gx * TEXT_SCALE, ty + gy * TEXT_SCALE, TEXT_SCALE, TEXT_SCALE, pal.text);
        };
    }
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    if (args.len != 2) {
        out.print("usage: zchess art <file-to-hash> <out.png>\n", .{});
        return;
    }
    const bytes = try Io.Dir.cwd().readFileAlloc(io, args[0], gpa, .unlimited);
    defer gpa.free(bytes);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});

    const dream = try dreamGame(gpa, io, h);
    var img = try Image.init(gpa, W, H, .{ 0, 0, 0 });
    defer img.deinit(gpa);
    render(&img, &dream.pos, dream.last, h);
    try img.savePng(gpa, io, args[1]);

    var fen_buf: [128]u8 = undefined;
    out.print("{s}: {x} -> {s}\n", .{ args[1], h[0..8], dream.pos.toFen(&fen_buf) });
}

test "sprites are 16x16" {
    for (sprites) |s| for (s) |row| try std.testing.expectEqual(@as(usize, 16), row.len);
}

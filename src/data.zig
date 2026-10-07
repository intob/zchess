//! Training record format: one 32-byte record per position.

const std = @import("std");
const bb = @import("bitboard.zig");
const Position = @import("position.zig").Position;

pub const Record = extern struct {
    occ: u64,
    /// One nibble per occupied square in ascending square order: color << 3 | type.
    pcs: [16]u8,
    /// Search score in centipawns from white's point of view.
    score: i16,
    /// Game outcome: 0 = black won, 1 = draw, 2 = white won.
    result: u8,
    stm: u8,
    ply: u16,
    _pad: [2]u8 = .{ 0, 0 },

    pub fn pack(pos: *const Position, white_score: i32, ply: u16) Record {
        var r = Record{
            .occ = pos.occupied(),
            .pcs = .{0} ** 16,
            .score = @intCast(std.math.clamp(white_score, -32000, 32000)),
            .result = 1,
            .stm = pos.side,
            .ply = ply,
        };
        var occ = r.occ;
        var i: usize = 0;
        while (occ != 0) : (i += 1) {
            const sq = bb.popLsb(&occ);
            const pc = pos.board[sq];
            const code: u8 = (@as(u8, bb.pieceColor(pc)) << 3) | bb.pieceType(pc);
            r.pcs[i / 2] |= code << @intCast(4 * (i % 2));
        }
        return r;
    }

    /// Rebuild a position (no castling or en passant information).
    pub fn toPosition(r: *const Record) Position {
        var pos = Position{};
        r.forEachPiece(&pos, struct {
            fn f(p: *Position, pc: bb.Piece, sq: bb.Square) void {
                p.addPiece(pc, sq);
            }
        }.f);
        pos.side = @intCast(r.stm);
        return pos;
    }

    /// Calls `f(ctx, piece, square)` for every piece in the record.
    pub inline fn forEachPiece(r: *const Record, ctx: anytype, comptime f: anytype) void {
        var occ = r.occ;
        var i: usize = 0;
        while (occ != 0) : (i += 1) {
            const sq = bb.popLsb(&occ);
            const code = (r.pcs[i / 2] >> @intCast(4 * (i % 2))) & 0xF;
            const pc = bb.makePiece(@intCast(code >> 3), @intCast(code & 7));
            f(ctx, pc, sq);
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(Record) == 32);
}

test "record round trip" {
    const atk = @import("attacks.zig");
    atk.init();
    const pos = try Position.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    const r = Record.pack(&pos, 123, 10);
    var board = [_]bb.Piece{bb.NO_PIECE} ** 64;
    r.forEachPiece(&board, struct {
        fn f(b: *[64]bb.Piece, pc: bb.Piece, sq: bb.Square) void {
            b[sq] = pc;
        }
    }.f);
    try std.testing.expectEqualSlices(bb.Piece, &pos.board, &board);
}

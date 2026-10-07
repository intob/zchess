//! Core board types and bitboard helpers.
//! Squares are numbered a1 = 0, b1 = 1, ..., h8 = 63.

pub const Square = u6;
pub const Color = u1;
pub const PieceType = u3;
/// color * 6 + piece type; NO_PIECE for empty squares.
pub const Piece = u4;

pub const WHITE: Color = 0;
pub const BLACK: Color = 1;

pub const PAWN: PieceType = 0;
pub const KNIGHT: PieceType = 1;
pub const BISHOP: PieceType = 2;
pub const ROOK: PieceType = 3;
pub const QUEEN: PieceType = 4;
pub const KING: PieceType = 5;

pub const NO_PIECE: Piece = 12;
pub const NO_SQ: u8 = 64;

pub const FILE_A: u64 = 0x0101010101010101;
pub const FILE_H: u64 = FILE_A << 7;
pub const RANK_1: u64 = 0xFF;
pub const RANK_2: u64 = RANK_1 << 8;
pub const RANK_7: u64 = RANK_1 << 48;
pub const RANK_8: u64 = RANK_1 << 56;

pub inline fn makePiece(c: Color, pt: PieceType) Piece {
    return @as(Piece, c) * 6 + pt;
}

pub inline fn pieceType(p: Piece) PieceType {
    return @intCast(p % 6);
}

pub inline fn pieceColor(p: Piece) Color {
    return @intCast(p / 6);
}

pub inline fn bit(sq: Square) u64 {
    return @as(u64, 1) << sq;
}

pub inline fn lsb(b: u64) Square {
    return @intCast(@ctz(b));
}

pub inline fn popLsb(b: *u64) Square {
    const s = lsb(b.*);
    b.* &= b.* - 1;
    return s;
}

pub inline fn popcount(b: u64) u32 {
    return @popCount(b);
}

pub inline fn moreThanOne(b: u64) bool {
    return b & (b -% 1) != 0;
}

pub inline fn fileOf(sq: Square) u3 {
    return @truncate(sq);
}

pub inline fn rankOf(sq: Square) u3 {
    return @intCast(sq >> 3);
}

pub fn squareName(sq: Square) [2]u8 {
    return .{ 'a' + @as(u8, fileOf(sq)), '1' + @as(u8, rankOf(sq)) };
}

pub fn parseSquare(s: []const u8) ?Square {
    if (s.len < 2) return null;
    if (s[0] < 'a' or s[0] > 'h' or s[1] < '1' or s[1] > '8') return null;
    return @intCast((s[1] - '1') * 8 + (s[0] - 'a'));
}

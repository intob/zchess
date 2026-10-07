//! Board state with copy-make move application and incremental Zobrist hashing.

const std = @import("std");
const bb = @import("bitboard.zig");
const atk = @import("attacks.zig");

const Square = bb.Square;
const Color = bb.Color;
const Piece = bb.Piece;
const PieceType = bb.PieceType;
const WHITE = bb.WHITE;
const BLACK = bb.BLACK;
const NO_PIECE = bb.NO_PIECE;
const NO_SQ = bb.NO_SQ;

pub const START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

pub const WK: u4 = 1;
pub const WQ: u4 = 2;
pub const BK: u4 = 4;
pub const BQ: u4 = 8;

/// 16-bit move: from (6) | to (6) | flag (4).
pub const Move = struct {
    data: u16,

    pub const QUIET: u4 = 0;
    pub const DOUBLE_PUSH: u4 = 1;
    pub const KING_CASTLE: u4 = 2;
    pub const QUEEN_CASTLE: u4 = 3;
    pub const CAPTURE: u4 = 4;
    pub const EP_CAPTURE: u4 = 5;
    pub const PROMO: u4 = 8; // + (piece type - 1), +4 if capture

    pub const none = Move{ .data = 0 };

    pub inline fn init(f: Square, t: Square, fl: u4) Move {
        return .{ .data = @as(u16, f) | (@as(u16, t) << 6) | (@as(u16, fl) << 12) };
    }
    pub inline fn from(m: Move) Square {
        return @truncate(m.data);
    }
    pub inline fn to(m: Move) Square {
        return @truncate(m.data >> 6);
    }
    pub inline fn flag(m: Move) u4 {
        return @intCast(m.data >> 12);
    }
    pub inline fn isCapture(m: Move) bool {
        return m.flag() & 4 != 0;
    }
    pub inline fn isPromotion(m: Move) bool {
        return m.flag() & 8 != 0;
    }
    pub inline fn isCastle(m: Move) bool {
        return m.flag() == KING_CASTLE or m.flag() == QUEEN_CASTLE;
    }
    pub inline fn isNoisy(m: Move) bool {
        return m.flag() & 12 != 0;
    }
    pub inline fn promoType(m: Move) PieceType {
        return @intCast((m.flag() & 3) + 1);
    }
    pub inline fn eql(a: Move, b: Move) bool {
        return a.data == b.data;
    }

    /// UCI notation, e.g. "e2e4" or "e7e8q". Returns the used slice of `buf`.
    pub fn toUci(m: Move, buf: *[5]u8) []const u8 {
        if (m.data == 0) {
            @memcpy(buf[0..4], "0000");
            return buf[0..4];
        }
        const f = bb.squareName(m.from());
        const t = bb.squareName(m.to());
        buf[0] = f[0];
        buf[1] = f[1];
        buf[2] = t[0];
        buf[3] = t[1];
        if (m.isPromotion()) {
            buf[4] = "nbrq"[m.promoType() - 1];
            return buf[0..5];
        }
        return buf[0..4];
    }
};

const Zobrist = struct {
    psq: [12][64]u64,
    side: u64,
    castle: [16]u64,
    ep: [8]u64,
};

pub const zobrist: Zobrist = blk: {
    @setEvalBranchQuota(100000);
    var z: Zobrist = undefined;
    var s: u64 = 0x2545F4914F6CDD1D;
    const next = struct {
        fn f(state: *u64) u64 {
            state.* +%= 0x9E3779B97F4A7C15;
            var x = state.*;
            x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
            x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
            return x ^ (x >> 31);
        }
    }.f;
    for (0..12) |p| {
        for (0..64) |q| z.psq[p][q] = next(&s);
    }
    z.side = next(&s);
    for (0..16) |c| z.castle[c] = next(&s);
    for (0..8) |f| z.ep[f] = next(&s);
    break :blk z;
};

/// Castling rights that survive a move touching each square.
const castle_mask: [64]u4 = blk: {
    var m = [_]u4{15} ** 64;
    m[0] = 15 & ~WQ; // a1
    m[7] = 15 & ~WK; // h1
    m[4] = 15 & ~(WK | WQ); // e1
    m[56] = 15 & ~BQ; // a8
    m[63] = 15 & ~BK; // h8
    m[60] = 15 & ~(BK | BQ); // e8
    break :blk m;
};

pub const PieceSq = struct { piece: Piece, sq: Square };

/// Pieces removed/added by the last move, for incremental NNUE updates.
pub const Dirty = struct {
    n_sub: u8 = 0,
    n_add: u8 = 0,
    sub: [2]PieceSq = undefined,
    add: [2]PieceSq = undefined,

    inline fn pushSub(d: *Dirty, p: Piece, sq: Square) void {
        d.sub[d.n_sub] = .{ .piece = p, .sq = sq };
        d.n_sub += 1;
    }
    inline fn pushAdd(d: *Dirty, p: Piece, sq: Square) void {
        d.add[d.n_add] = .{ .piece = p, .sq = sq };
        d.n_add += 1;
    }
};

pub const Position = struct {
    pieces: [6]u64 = .{0} ** 6,
    colors: [2]u64 = .{0} ** 2,
    board: [64]Piece = .{NO_PIECE} ** 64,
    side: Color = WHITE,
    castling: u4 = 0,
    ep: u8 = NO_SQ,
    halfmove: u16 = 0,
    fullmove: u16 = 1,
    key: u64 = 0,
    checkers: u64 = 0,
    dirty: Dirty = .{},

    pub inline fn occupied(p: *const Position) u64 {
        return p.colors[0] | p.colors[1];
    }

    pub inline fn piecesOf(p: *const Position, c: Color, pt: PieceType) u64 {
        return p.pieces[pt] & p.colors[c];
    }

    pub inline fn kingSq(p: *const Position, c: Color) Square {
        return bb.lsb(p.piecesOf(c, bb.KING));
    }

    pub inline fn inCheck(p: *const Position) bool {
        return p.checkers != 0;
    }

    pub inline fn addPiece(p: *Position, pc: Piece, sq: Square) void {
        const b = bb.bit(sq);
        p.pieces[bb.pieceType(pc)] |= b;
        p.colors[bb.pieceColor(pc)] |= b;
        p.board[sq] = pc;
        p.key ^= zobrist.psq[pc][sq];
    }

    pub inline fn removePiece(p: *Position, sq: Square) void {
        const pc = p.board[sq];
        const b = bb.bit(sq);
        p.pieces[bb.pieceType(pc)] &= ~b;
        p.colors[bb.pieceColor(pc)] &= ~b;
        p.board[sq] = NO_PIECE;
        p.key ^= zobrist.psq[pc][sq];
    }

    /// All pieces of both colors attacking `sq` given occupancy `occ`.
    pub inline fn attackersTo(p: *const Position, sq: Square, occ: u64) u64 {
        const bq = p.pieces[bb.BISHOP] | p.pieces[bb.QUEEN];
        const rq = p.pieces[bb.ROOK] | p.pieces[bb.QUEEN];
        return (atk.pawn[WHITE][sq] & p.piecesOf(BLACK, bb.PAWN)) |
            (atk.pawn[BLACK][sq] & p.piecesOf(WHITE, bb.PAWN)) |
            (atk.knight[sq] & p.pieces[bb.KNIGHT]) |
            (atk.king[sq] & p.pieces[bb.KING]) |
            (atk.bishop(sq, occ) & bq) |
            (atk.rook(sq, occ) & rq);
    }

    /// Is `sq` attacked by pieces of color `by` given occupancy `occ`?
    pub inline fn attackedBy(p: *const Position, sq: Square, by: Color, occ: u64) bool {
        const them = p.colors[by];
        if (atk.pawn[by ^ 1][sq] & p.pieces[bb.PAWN] & them != 0) return true;
        if (atk.knight[sq] & p.pieces[bb.KNIGHT] & them != 0) return true;
        if (atk.king[sq] & p.pieces[bb.KING] & them != 0) return true;
        if (atk.bishop(sq, occ) & (p.pieces[bb.BISHOP] | p.pieces[bb.QUEEN]) & them != 0) return true;
        if (atk.rook(sq, occ) & (p.pieces[bb.ROOK] | p.pieces[bb.QUEEN]) & them != 0) return true;
        return false;
    }

    pub fn hasNonPawnMaterial(p: *const Position, c: Color) bool {
        return (p.pieces[bb.KNIGHT] | p.pieces[bb.BISHOP] | p.pieces[bb.ROOK] | p.pieces[bb.QUEEN]) & p.colors[c] != 0;
    }

    pub fn isInsufficientMaterial(p: *const Position) bool {
        if (p.pieces[bb.PAWN] | p.pieces[bb.ROOK] | p.pieces[bb.QUEEN] != 0) return false;
        return bb.popcount(p.occupied()) <= 3; // K v K, K+minor v K
    }

    pub fn makeMove(self: *const Position, m: Move) Position {
        var p = self.*;
        p.dirty = .{};
        const from = m.from();
        const to = m.to();
        const fl = m.flag();
        const us = self.side;
        const them = us ^ 1;
        const piece = self.board[from];
        const pt = bb.pieceType(piece);

        p.halfmove += 1;
        if (p.ep != NO_SQ) {
            p.key ^= zobrist.ep[p.ep & 7];
            p.ep = NO_SQ;
        }

        if (fl == Move.EP_CAPTURE) {
            const cap_sq: Square = to ^ 8;
            p.dirty.pushSub(p.board[cap_sq], cap_sq);
            p.removePiece(cap_sq);
        } else if (self.board[to] != NO_PIECE) {
            p.dirty.pushSub(self.board[to], to);
            p.removePiece(to);
            p.halfmove = 0;
        }

        p.dirty.pushSub(piece, from);
        p.removePiece(from);
        const placed = if (m.isPromotion()) bb.makePiece(us, m.promoType()) else piece;
        p.addPiece(placed, to);
        p.dirty.pushAdd(placed, to);

        if (pt == bb.PAWN) {
            p.halfmove = 0;
            if (fl == Move.DOUBLE_PUSH) {
                const ep_sq: Square = if (us == WHITE) from + 8 else from - 8;
                // Only record the ep square if an enemy pawn can capture onto it.
                if (atk.pawn[us][ep_sq] & p.piecesOf(them, bb.PAWN) != 0) {
                    p.ep = ep_sq;
                    p.key ^= zobrist.ep[ep_sq & 7];
                }
            }
        } else if (fl == Move.KING_CASTLE or fl == Move.QUEEN_CASTLE) {
            const rook_from: Square = if (fl == Move.KING_CASTLE) to + 1 else to - 2;
            const rook_to: Square = if (fl == Move.KING_CASTLE) to - 1 else to + 1;
            const rk = bb.makePiece(us, bb.ROOK);
            p.removePiece(rook_from);
            p.addPiece(rk, rook_to);
            p.dirty.pushSub(rk, rook_from);
            p.dirty.pushAdd(rk, rook_to);
        }

        p.key ^= zobrist.castle[p.castling];
        p.castling &= castle_mask[from] & castle_mask[to];
        p.key ^= zobrist.castle[p.castling];

        p.side = them;
        p.key ^= zobrist.side;
        if (us == BLACK) p.fullmove += 1;
        p.checkers = p.attackersTo(p.kingSq(them), p.occupied()) & p.colors[us];
        return p;
    }

    pub fn makeNull(self: *const Position) Position {
        var p = self.*;
        p.dirty = .{};
        if (p.ep != NO_SQ) {
            p.key ^= zobrist.ep[p.ep & 7];
            p.ep = NO_SQ;
        }
        p.halfmove += 1;
        p.side ^= 1;
        p.key ^= zobrist.side;
        p.checkers = 0;
        return p;
    }

    pub fn fromFen(fen: []const u8) !Position {
        var p = Position{};
        var it = std.mem.tokenizeScalar(u8, fen, ' ');
        const placement = it.next() orelse return error.InvalidFen;
        var rank: i32 = 7;
        var file: i32 = 0;
        for (placement) |c| {
            switch (c) {
                '/' => {
                    rank -= 1;
                    file = 0;
                },
                '1'...'8' => file += c - '0',
                else => {
                    const idx = std.mem.indexOfScalar(u8, "PNBRQKpnbrqk", c) orelse return error.InvalidFen;
                    if (rank < 0 or file > 7) return error.InvalidFen;
                    p.addPiece(@intCast(idx), @intCast(rank * 8 + file));
                    file += 1;
                },
            }
        }
        if (bb.popcount(p.piecesOf(WHITE, bb.KING)) != 1 or bb.popcount(p.piecesOf(BLACK, bb.KING)) != 1)
            return error.InvalidFen;

        const stm = it.next() orelse "w";
        p.side = if (stm[0] == 'b') BLACK else WHITE;
        if (p.side == BLACK) p.key ^= zobrist.side;

        const castle = it.next() orelse "-";
        for (castle) |c| {
            switch (c) {
                'K' => p.castling |= WK,
                'Q' => p.castling |= WQ,
                'k' => p.castling |= BK,
                'q' => p.castling |= BQ,
                else => {},
            }
        }
        // Drop rights the board contradicts.
        if (p.board[4] != bb.makePiece(WHITE, bb.KING)) p.castling &= ~(WK | WQ);
        if (p.board[7] != bb.makePiece(WHITE, bb.ROOK)) p.castling &= ~WK;
        if (p.board[0] != bb.makePiece(WHITE, bb.ROOK)) p.castling &= ~WQ;
        if (p.board[60] != bb.makePiece(BLACK, bb.KING)) p.castling &= ~(BK | BQ);
        if (p.board[63] != bb.makePiece(BLACK, bb.ROOK)) p.castling &= ~BK;
        if (p.board[56] != bb.makePiece(BLACK, bb.ROOK)) p.castling &= ~BQ;
        p.key ^= zobrist.castle[p.castling];

        const ep = it.next() orelse "-";
        if (bb.parseSquare(ep)) |sq| {
            // Only record the ep square if a capture is actually possible.
            if (atk.pawn[p.side ^ 1][sq] & p.piecesOf(p.side, bb.PAWN) != 0) {
                p.ep = sq;
                p.key ^= zobrist.ep[sq & 7];
            }
        }
        if (it.next()) |hm| p.halfmove = std.fmt.parseInt(u16, hm, 10) catch 0;
        if (it.next()) |fm| p.fullmove = std.fmt.parseInt(u16, fm, 10) catch 1;

        p.checkers = p.attackersTo(p.kingSq(p.side), p.occupied()) & p.colors[p.side ^ 1];
        // The side not to move must not be in check.
        if (p.attackedBy(p.kingSq(p.side ^ 1), p.side, p.occupied())) return error.InvalidFen;
        return p;
    }

    pub fn startpos() Position {
        return fromFen(START_FEN) catch unreachable;
    }

    pub fn toFen(p: *const Position, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var rank: i32 = 7;
        while (rank >= 0) : (rank -= 1) {
            var empty: u8 = 0;
            for (0..8) |f| {
                const pc = p.board[@intCast(rank * 8 + @as(i32, @intCast(f)))];
                if (pc == NO_PIECE) {
                    empty += 1;
                } else {
                    if (empty > 0) w.writeByte('0' + empty) catch {};
                    empty = 0;
                    w.writeByte("PNBRQKpnbrqk"[pc]) catch {};
                }
            }
            if (empty > 0) w.writeByte('0' + empty) catch {};
            if (rank > 0) w.writeByte('/') catch {};
        }
        w.writeAll(if (p.side == WHITE) " w " else " b ") catch {};
        if (p.castling == 0) w.writeByte('-') catch {};
        if (p.castling & WK != 0) w.writeByte('K') catch {};
        if (p.castling & WQ != 0) w.writeByte('Q') catch {};
        if (p.castling & BK != 0) w.writeByte('k') catch {};
        if (p.castling & BQ != 0) w.writeByte('q') catch {};
        if (p.ep != NO_SQ) {
            const n = bb.squareName(@intCast(p.ep));
            w.print(" {s}", .{&n}) catch {};
        } else w.writeAll(" -") catch {};
        w.print(" {d} {d}", .{ p.halfmove, p.fullmove }) catch {};
        return w.buffered();
    }

    pub fn print(p: *const Position, w: *std.Io.Writer) !void {
        var rank: i32 = 7;
        while (rank >= 0) : (rank -= 1) {
            try w.print(" {d}  ", .{rank + 1});
            for (0..8) |f| {
                const pc = p.board[@intCast(rank * 8 + @as(i32, @intCast(f)))];
                try w.print("{c} ", .{if (pc == NO_PIECE) @as(u8, '.') else "PNBRQKpnbrqk"[pc]});
            }
            try w.writeByte('\n');
        }
        try w.writeAll("\n    a b c d e f g h\n\n");
        var buf: [128]u8 = undefined;
        try w.print("Fen: {s}\nKey: {x:0>16}\n", .{ p.toFen(&buf), p.key });
    }
};

//! Fully legal move generation using check masks and pin rays.

const bb = @import("bitboard.zig");
const atk = @import("attacks.zig");
const position = @import("position.zig");

const Position = position.Position;
const Move = position.Move;
const Square = bb.Square;
const WHITE = bb.WHITE;

pub const MoveList = struct {
    moves: [256]Move = undefined,
    len: usize = 0,

    pub inline fn add(l: *MoveList, m: Move) void {
        l.moves[l.len] = m;
        l.len += 1;
    }

    pub fn slice(l: *const MoveList) []const Move {
        return l.moves[0..l.len];
    }
};

pub const Mode = enum {
    /// Every legal move.
    all,
    /// Captures and queen promotions only (for quiescence search).
    noisy,
};

pub fn pinned(pos: *const Position, us: bb.Color) u64 {
    const them = us ^ 1;
    const ksq = pos.kingSq(us);
    const occ = pos.occupied();
    var snipers = ((atk.rook(ksq, 0) & (pos.pieces[bb.ROOK] | pos.pieces[bb.QUEEN])) |
        (atk.bishop(ksq, 0) & (pos.pieces[bb.BISHOP] | pos.pieces[bb.QUEEN]))) & pos.colors[them];
    var result: u64 = 0;
    while (snipers != 0) {
        const s = bb.popLsb(&snipers);
        const b = atk.between[ksq][s] & occ;
        if (b != 0 and !bb.moreThanOne(b) and b & pos.colors[us] != 0) result |= b;
    }
    return result;
}

inline fn addPromos(list: *MoveList, from: Square, to: Square, capture: bool, comptime mode: Mode) void {
    const base: u4 = if (capture) Move.PROMO | 4 else Move.PROMO;
    list.add(Move.init(from, to, base | 3)); // queen
    if (mode == .all) {
        list.add(Move.init(from, to, base | 0));
        list.add(Move.init(from, to, base | 1));
        list.add(Move.init(from, to, base | 2));
    }
}

inline fn addTargets(list: *MoveList, from: Square, targets: u64, enemy: u64) void {
    var t = targets;
    while (t != 0) {
        const to = bb.popLsb(&t);
        list.add(Move.init(from, to, if (enemy & bb.bit(to) != 0) Move.CAPTURE else Move.QUIET));
    }
}

pub fn generate(pos: *const Position, list: *MoveList, comptime mode: Mode) void {
    const us = pos.side;
    const them = us ^ 1;
    const own = pos.colors[us];
    const enemy = pos.colors[them];
    const occ = own | enemy;
    const ksq = pos.kingSq(us);
    const checkers = pos.checkers;

    // King moves: the destination must not be attacked once the king has left.
    {
        var targets = atk.king[ksq] & ~own;
        if (mode == .noisy) targets &= enemy;
        const occ_no_king = occ ^ bb.bit(ksq);
        while (targets != 0) {
            const to = bb.popLsb(&targets);
            if (!pos.attackedBy(to, them, occ_no_king))
                list.add(Move.init(ksq, to, if (enemy & bb.bit(to) != 0) Move.CAPTURE else Move.QUIET));
        }
    }
    if (bb.moreThanOne(checkers)) return;

    const check_mask: u64 = if (checkers != 0) atk.between[ksq][bb.lsb(checkers)] | checkers else ~@as(u64, 0);
    const pins = pinned(pos, us);
    var target_mask = ~own & check_mask;
    if (mode == .noisy) target_mask &= enemy;

    // Castling: rights guarantee king and rook are on their home squares.
    if (mode == .all and checkers == 0) {
        if (us == WHITE) {
            if (pos.castling & position.WK != 0 and occ & 0x60 == 0 and
                !pos.attackedBy(5, them, occ) and !pos.attackedBy(6, them, occ))
                list.add(Move.init(4, 6, Move.KING_CASTLE));
            if (pos.castling & position.WQ != 0 and occ & 0x0E == 0 and
                !pos.attackedBy(3, them, occ) and !pos.attackedBy(2, them, occ))
                list.add(Move.init(4, 2, Move.QUEEN_CASTLE));
        } else {
            if (pos.castling & position.BK != 0 and occ & (0x60 << 56) == 0 and
                !pos.attackedBy(61, them, occ) and !pos.attackedBy(62, them, occ))
                list.add(Move.init(60, 62, Move.KING_CASTLE));
            if (pos.castling & position.BQ != 0 and occ & (0x0E << 56) == 0 and
                !pos.attackedBy(59, them, occ) and !pos.attackedBy(58, them, occ))
                list.add(Move.init(60, 58, Move.QUEEN_CASTLE));
        }
    }

    // Knights: a pinned knight can never move.
    var knights = pos.pieces[bb.KNIGHT] & own & ~pins;
    while (knights != 0) {
        const from = bb.popLsb(&knights);
        addTargets(list, from, atk.knight[from] & target_mask, enemy);
    }

    var diag = (pos.pieces[bb.BISHOP] | pos.pieces[bb.QUEEN]) & own;
    while (diag != 0) {
        const from = bb.popLsb(&diag);
        var t = atk.bishop(from, occ) & target_mask;
        if (pins & bb.bit(from) != 0) t &= atk.line[ksq][from];
        addTargets(list, from, t, enemy);
    }

    var orth = (pos.pieces[bb.ROOK] | pos.pieces[bb.QUEEN]) & own;
    while (orth != 0) {
        const from = bb.popLsb(&orth);
        var t = atk.rook(from, occ) & target_mask;
        if (pins & bb.bit(from) != 0) t &= atk.line[ksq][from];
        addTargets(list, from, t, enemy);
    }

    // Pawns.
    const promo_rank: u64 = if (us == WHITE) bb.RANK_8 else bb.RANK_1;
    const start_rank: u64 = if (us == WHITE) bb.RANK_2 else bb.RANK_7;
    var pawns = pos.pieces[bb.PAWN] & own;
    while (pawns != 0) {
        const from = bb.popLsb(&pawns);
        const restrict: u64 = if (pins & bb.bit(from) != 0) atk.line[ksq][from] else ~@as(u64, 0);
        const mask = check_mask & restrict;

        const one: Square = if (us == WHITE) from + 8 else from - 8;
        if (pos.board[one] == bb.NO_PIECE) {
            if (bb.bit(one) & promo_rank != 0) {
                if (bb.bit(one) & mask != 0) addPromos(list, from, one, false, mode);
            } else if (mode == .all) {
                if (bb.bit(one) & mask != 0) list.add(Move.init(from, one, Move.QUIET));
                if (bb.bit(from) & start_rank != 0) {
                    const two: Square = if (us == WHITE) one + 8 else one - 8;
                    if (pos.board[two] == bb.NO_PIECE and bb.bit(two) & mask != 0)
                        list.add(Move.init(from, two, Move.DOUBLE_PUSH));
                }
            }
        }

        var caps = atk.pawn[us][from] & enemy & mask;
        while (caps != 0) {
            const to = bb.popLsb(&caps);
            if (bb.bit(to) & promo_rank != 0) {
                addPromos(list, from, to, true, mode);
            } else list.add(Move.init(from, to, Move.CAPTURE));
        }

        if (pos.ep != bb.NO_SQ) {
            const ep: Square = @intCast(pos.ep);
            if (atk.pawn[us][from] & bb.bit(ep) != 0) {
                // Rare enough to verify by brute force: covers checks and
                // the horizontal pin through both pawns.
                const cap_sq: Square = ep ^ 8;
                const occ2 = (occ ^ bb.bit(from) ^ bb.bit(cap_sq)) | bb.bit(ep);
                if (pos.attackersTo(ksq, occ2) & enemy & ~bb.bit(cap_sq) == 0)
                    list.add(Move.init(from, ep, Move.EP_CAPTURE));
            }
        }
    }
}

pub fn perft(pos: *const Position, depth: u32) u64 {
    var list = MoveList{};
    generate(pos, &list, .all);
    if (depth <= 1) return if (depth == 0) 1 else list.len;
    var n: u64 = 0;
    for (list.slice()) |m| {
        const child = pos.makeMove(m);
        n += perft(&child, depth - 1);
    }
    return n;
}

/// Find the legal move matching a UCI string, if any.
pub fn parseUci(pos: *const Position, s: []const u8) ?Move {
    var list = MoveList{};
    generate(pos, &list, .all);
    for (list.slice()) |m| {
        var buf: [5]u8 = undefined;
        const u = m.toUci(&buf);
        if (u.len == s.len and @import("std").mem.eql(u8, u, s)) return m;
    }
    return null;
}

pub const PerftCase = struct { fen: []const u8, depth: u32, nodes: u64 };

pub const perft_suite = [_]PerftCase{
    .{ .fen = position.START_FEN, .depth = 6, .nodes = 119060324 },
    .{ .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 5, .nodes = 193690690 },
    .{ .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 6, .nodes = 11030083 },
    .{ .fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .depth = 5, .nodes = 15833292 },
    .{ .fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", .depth = 5, .nodes = 89941194 },
    .{ .fen = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", .depth = 5, .nodes = 164075551 },
};

test "perft shallow" {
    const std = @import("std");
    atk.init();
    const shallow = [_]PerftCase{
        .{ .fen = position.START_FEN, .depth = 4, .nodes = 197281 },
        .{ .fen = perft_suite[1].fen, .depth = 3, .nodes = 97862 },
        .{ .fen = perft_suite[2].fen, .depth = 5, .nodes = 674624 },
        .{ .fen = perft_suite[3].fen, .depth = 4, .nodes = 422333 },
        .{ .fen = perft_suite[4].fen, .depth = 3, .nodes = 62379 },
        .{ .fen = perft_suite[5].fen, .depth = 3, .nodes = 89890 },
    };
    for (shallow) |c| {
        const pos = try Position.fromFen(c.fen);
        try std.testing.expectEqual(c.nodes, perft(&pos, c.depth));
    }
}

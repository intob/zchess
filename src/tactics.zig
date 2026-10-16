//! Names the tactic behind a move: fork, pin, skewer, discovered attack or
//! check, double check, trapped piece, removing the defender, and the
//! back-rank and smothered mates. Review and the coach use it to say why a
//! move wins or loses material, not just that it does. Also finds the loose
//! pieces a side has (for the coach's hints).

const std = @import("std");
const bb = @import("bitboard.zig");
const atk = @import("attacks.zig");
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const search = @import("search.zig");

const Position = position.Position;
const Move = position.Move;
const PieceType = bb.PieceType;
const Square = bb.Square;

pub const Motif = enum {
    none,
    fork,
    pin,
    skewer,
    discovered_attack,
    discovered_check,
    double_check,
    trapped_piece,
    removed_defender,
    back_rank_mate,
    smothered_mate,
};

pub const Hit = struct {
    motif: Motif = .none,
    /// The piece carrying it out (for a discovered attack, the one that moves).
    by: ?PieceType = null,
    /// What it hits: the two forked pieces, the pinned piece and what it is
    /// pinned to, the skewered piece and the one behind, the piece won by a
    /// discovery, the trapped piece, or the piece the defender was guarding.
    targets: [2]?PieceType = .{ null, null },
    /// Where the key move comes in the line it was found in (set by callers
    /// that search past the first move).
    at: u8 = 0,
};

const value = [6]i32{ 100, 300, 300, 500, 900, 10000 };

fn attacksFrom(pt: PieceType, c: bb.Color, sq: Square, occ: u64) u64 {
    return switch (pt) {
        bb.PAWN => atk.pawn[c][sq],
        bb.KNIGHT => atk.knight[sq],
        bb.BISHOP => atk.bishop(sq, occ),
        bb.ROOK => atk.rook(sq, occ),
        bb.QUEEN => atk.queen(sq, occ),
        else => atk.king[sq],
    };
}

fn victimOf(p: *const Position, m: Move) ?PieceType {
    if (m.flag() == Move.EP_CAPTURE) return bb.PAWN;
    if (!m.isCapture()) return null;
    return typeAt(p, m.to());
}

fn typeAt(p: *const Position, sq: Square) PieceType {
    return bb.pieceType(p.board[sq]);
}

fn defended(p: *const Position, sq: Square) bool {
    const c = bb.pieceColor(p.board[sq]);
    return p.attackersTo(sq, p.occupied()) & p.colors[c] & ~bb.bit(sq) != 0;
}

/// Whether attacking the piece on `sq` with a `by` threatens to win something:
/// the king, anything worth more than the attacker, or an undefended piece.
/// Pawns don't count; losing one is rarely the lesson.
fn target(p: *const Position, sq: Square, by: PieceType) bool {
    const t = typeAt(p, sq);
    if (t == bb.KING) return true;
    if (t == bb.PAWN) return false;
    return value[t] > value[by] or !defended(p, sq);
}

/// The two most valuable targets in `squares`, as attacked by a `by`.
fn bestTargets(p: *const Position, squares: u64, by: PieceType) struct { n: u32, t: [2]?PieceType } {
    var out: [2]?PieceType = .{ null, null };
    var n: u32 = 0;
    var s = squares;
    while (s != 0) {
        const sq = bb.popLsb(&s);
        if (!target(p, sq, by)) continue;
        n += 1;
        const t = typeAt(p, sq);
        if (out[0] == null or value[t] > value[out[0].?]) {
            out[1] = out[0];
            out[0] = t;
        } else if (out[1] == null or value[t] > value[out[1].?]) {
            out[1] = t;
        }
    }
    return .{ .n = n, .t = out };
}

/// The tactic in the line `pv` played from `start`, judged mostly by its
/// first move. `.none` when nothing is recognised.
pub fn find(start: *const Position, pv: []const Move) Hit {
    if (pv.len == 0 or pv[0].data == 0) return .{};
    if (mate(start, pv)) |h| return h;

    const m = pv[0];
    const us = start.side;
    const them = us ^ 1;
    const after = start.makeMove(m);
    const to = m.to();
    const pt = typeAt(&after, to);
    const occ = after.occupied();
    const enemy = after.colors[them];
    const hits = attacksFrom(pt, us, to, occ) & enemy;
    // The moved piece can't simply be taken for nothing.
    const safe = search.see(start, m, 0);

    if (bb.popcount(after.checkers) >= 2) return .{ .motif = .double_check, .by = pt };
    if (after.checkers != 0 and after.checkers & bb.bit(to) == 0) {
        // What the moving piece then hits, and what it took.
        return .{ .motif = .discovered_check, .by = pt, .targets = .{ bestTargets(&after, hits, pt).t[0], victimOf(start, m) } };
    }

    if (safe) {
        const f = bestTargets(&after, hits, pt);
        if (f.n >= 2) return .{ .motif = .fork, .by = pt, .targets = f.t };
    }

    if (safe and (pt == bb.BISHOP or pt == bb.ROOK or pt == bb.QUEEN)) {
        var xs = hits & ~after.pieces[bb.PAWN];
        while (xs != 0) {
            const x = bb.popLsb(&xs);
            // The first piece behind x on the line from the slider.
            const behind = attacksFrom(pt, us, to, occ ^ bb.bit(x)) & ~attacksFrom(pt, us, to, occ) & atk.line[to][x] & enemy;
            if (behind == 0) continue;
            const y = bb.lsb(behind);
            const xt = typeAt(&after, x);
            const yt = typeAt(&after, y);
            if (yt == bb.PAWN) continue;
            // Pinned to the king, to something worth more, or to an
            // undefended piece that would fall if it moved.
            const y_loose = !defended(&after, y) and yt >= bb.KNIGHT;
            if (xt != bb.KING and (yt == bb.KING or value[yt] > value[xt] or y_loose) and (value[yt] > value[pt] or y_loose))
                return .{ .motif = .pin, .by = pt, .targets = .{ xt, yt } };
            if ((xt == bb.KING or value[xt] > value[yt]) and target(&after, x, pt) and (value[yt] > value[pt] or !defended(&after, y)))
                return .{ .motif = .skewer, .by = pt, .targets = .{ xt, yt } };
        }
    }

    // A line opened by the move: one of our other sliders now hits a target,
    // or any piece while the moving piece itself hits a target (two threats).
    const own_threat = bestTargets(&after, hits, pt).t[0];
    var sliders = (after.pieces[bb.BISHOP] | after.pieces[bb.ROOK] | after.pieces[bb.QUEEN]) & after.colors[us] & ~bb.bit(to);
    const occ_before = start.occupied();
    while (sliders != 0) {
        const s = bb.popLsb(&sliders);
        const st = typeAt(&after, s);
        const fresh = attacksFrom(st, us, s, occ) & ~attacksFrom(st, us, s, occ_before) & enemy;
        const d = bestTargets(&after, fresh, st);
        if (d.n > 0) return .{ .motif = .discovered_attack, .by = pt, .targets = .{ d.t[0], own_threat } };
        const pieces = fresh & ~after.pieces[bb.PAWN];
        if (own_threat != null and pieces != 0) {
            var best: PieceType = bb.PAWN;
            var ps = pieces;
            while (ps != 0) best = @max(best, typeAt(&after, bb.popLsb(&ps)));
            return .{ .motif = .discovered_attack, .by = pt, .targets = .{ best, own_threat } };
        }
    }

    // Taking a defender, then what it defended.
    if (m.isCapture() and pv.len >= 3 and pv[2].isCapture()) {
        const t = pv[2].to();
        const defender = start.board[to];
        if (t != to and bb.pieceColor(defender) == them and
            attacksFrom(bb.pieceType(defender), them, to, occ_before) & bb.bit(t) != 0 and
            start.board[t] != bb.NO_PIECE and bb.pieceColor(start.board[t]) == them and
            typeAt(start, t) != bb.PAWN)
        {
            return .{ .motif = .removed_defender, .by = pt, .targets = .{ typeAt(start, t), null } };
        }
    }

    // A piece attacked with nowhere safe to go.
    if (safe and !m.isCapture()) {
        var xs = hits & ~after.pieces[bb.PAWN] & ~after.pieces[bb.KING];
        while (xs != 0) {
            const x = bb.popLsb(&xs);
            if (!target(&after, x, pt)) continue;
            if (!canEscape(&after, x)) return .{ .motif = .trapped_piece, .by = pt, .targets = .{ typeAt(&after, x), null } };
        }
    }
    return .{};
}

/// Whether the piece on `sq` (its side to move) has a move that doesn't lose it.
fn canEscape(p: *const Position, sq: Square) bool {
    var list = movegen.MoveList{};
    movegen.generate(p, &list, .all);
    for (list.slice()) |mv| {
        if (mv.from() == sq and search.see(p, mv, 0)) return true;
    }
    return false;
}

/// A back-rank or smothered mate at the end of `pv`.
fn mate(start: *const Position, pv: []const Move) ?Hit {
    var p = start.*;
    var last = Move.none;
    for (pv) |m| {
        if (m.data == 0) return null;
        last = m;
        p = p.makeMove(m);
    }
    if (!p.inCheck()) return null;
    var list = movegen.MoveList{};
    movegen.generate(&p, &list, .all);
    if (list.len != 0) return null;
    // Only the mating side's own mates count (the line ends on its move).
    if (pv.len % 2 == 0) return null;

    const ksq = p.kingSq(p.side);
    const own = p.colors[p.side];
    const by = typeAt(&p, last.to());
    if (by == bb.KNIGHT and atk.king[ksq] & ~own == 0) return .{ .motif = .smothered_mate, .by = by };
    const back: u3 = if (p.side == bb.WHITE) 0 else 7;
    if (bb.rankOf(ksq) == back and (by == bb.ROOK or by == bb.QUEEN) and bb.rankOf(last.to()) == back) {
        const forward: u64 = if (p.side == bb.WHITE) atk.king[ksq] & (bb.RANK_1 << 8) else atk.king[ksq] & (bb.RANK_1 << 48);
        if (forward & ~own == 0) return .{ .motif = .back_rank_mate, .by = by };
    }
    return null;
}

/// Pieces of side `c` (not pawns or the king) that can be taken for profit
/// right now: attacked, and undefended or attacked by something cheaper.
pub fn loosePieces(p: *const Position, c: bb.Color) u64 {
    var out: u64 = 0;
    var pieces = p.colors[c] & ~p.pieces[bb.PAWN] & ~p.pieces[bb.KING];
    const occ = p.occupied();
    while (pieces != 0) {
        const sq = bb.popLsb(&pieces);
        const attackers = p.attackersTo(sq, occ) & p.colors[c ^ 1];
        if (attackers == 0) continue;
        if (cheapest(p, attackers) < value[typeAt(p, sq)] or !defended(p, sq)) out |= bb.bit(sq);
    }
    return out;
}

/// The value of the cheapest piece among `attackers`.
pub fn cheapest(p: *const Position, attackers: u64) i32 {
    var best: i32 = std.math.maxInt(i32);
    var a = attackers;
    while (a != 0) best = @min(best, value[typeAt(p, bb.popLsb(&a))]);
    return best;
}

pub fn cheapestType(p: *const Position, attackers: u64) PieceType {
    var best: PieceType = bb.KING;
    var a = attackers;
    while (a != 0) {
        const t = typeAt(p, bb.popLsb(&a));
        if (value[t] < value[best]) best = t;
    }
    return best;
}

pub fn isDefended(p: *const Position, sq: Square) bool {
    return defended(p, sq);
}

fn parseLine(p: Position, sans: []const []const u8) ![]Move {
    const play = @import("play.zig");
    var moves = try std.testing.allocator.alloc(Move, sans.len);
    var q = p;
    for (sans, 0..) |s, i| {
        moves[i] = play.parseMove(&q, s) orelse return error.BadMove;
        q = q.makeMove(moves[i]);
    }
    return moves;
}

fn expectMotif(fen: []const u8, sans: []const []const u8, motif: Motif, targets: [2]?PieceType) !void {
    atk.init();
    const p = try Position.fromFen(fen);
    const pv = try parseLine(p, sans);
    defer std.testing.allocator.free(pv);
    const h = find(&p, pv);
    try std.testing.expectEqual(motif, h.motif);
    try std.testing.expectEqual(targets, h.targets);
}

test "tactics: motifs" {
    try expectMotif("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1", &.{"Nc7+"}, .fork, .{ bb.KING, bb.ROOK });
    try expectMotif("4k3/3n4/8/8/8/8/8/4KB2 w - - 0 1", &.{"Bb5"}, .pin, .{ bb.KNIGHT, bb.KING });
    // Pinned to an undefended bishop of the same value (from one of the user's games).
    try expectMotif("3r1rk1/p1Q3pp/4b3/1p3n2/5P2/6P1/P6P/1KB2B1R w - - 0 25", &.{"Bh3"}, .pin, .{ bb.KNIGHT, bb.BISHOP });
    // The knight hits the queen and uncovers the queen's attack on the bishop.
    try expectMotif("3k3r/1pp3pp/1r1q4/pB1pn3/P2Q1BPb/7P/1P6/RN3KR1 b - - 1 20", &.{"Nc6"}, .discovered_attack, .{ bb.BISHOP, bb.QUEEN });
    try expectMotif("4q3/8/8/8/4k3/8/8/K6R w - - 0 1", &.{"Re1+"}, .skewer, .{ bb.KING, bb.QUEEN });
    try expectMotif("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", &.{"Ra8#"}, .back_rank_mate, .{ null, null });
    try expectMotif("6rk/6pp/8/6N1/8/8/8/6K1 w - - 0 1", &.{"Nf7#"}, .smothered_mate, .{ null, null });
    try expectMotif("4k3/8/8/8/8/5K2/8/7n w - - 0 1", &.{"Kg2"}, .trapped_piece, .{ bb.KNIGHT, null });
    try expectMotif("6k1/6p1/5n2/3b4/8/8/1B6/3Q2K1 w - - 0 1", &.{ "Bxf6", "gxf6", "Qxd5" }, .removed_defender, .{ bb.BISHOP, null });
    // Berlin, 6...Nxb5?? 7.Nxc6+: the rook on e1 gives check, the knight hits the queen.
    try expectMotif("r1bqkb1r/pppp1ppp/2n5/1n2N3/8/8/PPPP1PPP/RNBQR1K1 w kq - 0 7", &.{"Nxc6+"}, .discovered_check, .{ bb.QUEEN, bb.KNIGHT });
}

test "tactics: loose pieces" {
    atk.init();
    // The knight on c6 is attacked by a pawn; the bishop on b5 isn't attacked.
    const p = try Position.fromFen("4k3/8/2n5/1b1P4/8/8/8/R3K3 b - - 0 1");
    try std.testing.expectEqual(bb.bit(42), loosePieces(&p, bb.BLACK) & bb.bit(42));
    try std.testing.expectEqual(@as(u64, 0), loosePieces(&p, bb.BLACK) & bb.bit(33));
}

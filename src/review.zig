//! Game review: replays a player's games, searches every position, and flags
//! the player's inaccuracies, mistakes and blunders by the drop in winning
//! chances (Lichess-style win%, so losing a pawn in a won position barely
//! counts). Each flagged move gets a plain-language label (hung a piece,
//! missed a capture, missed / allowed mate) plus the better move and line.
//! Writes a JSON report and an annotated PGN for En Croissant.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const cli = @import("cli.zig");
const pgn = @import("pgn.zig");
const play = @import("play.zig");
const TT = @import("tt.zig").TT;
const tactics = @import("tactics.zig");
const openings = @import("openings.zig");
const coach = @import("coach.zig");
const Output = @import("output.zig").Output;

const Position = position.Position;
const Move = position.Move;

const help =
    \\usage: zchess review --user <name> [options] <games.pgn>...
    \\
    \\  --user <name>      whose moves to review (matched against White/Black)
    \\  --json <file>      JSON report (default review.json)
    \\  --pgn <file>       annotated PGN for a GUI (default review.pgn)
    \\  --nodes <n>        search nodes per position (default 300000)
    \\  --threads <n>      games analysed in parallel (default: all cores)
    \\  --net <file|hce>   evaluation (default: embedded net)
    \\
;

pub const Class = enum { good, inaccuracy, mistake, blunder };

/// Summary.result in the JSON and the console.
const result_names = [_][]const u8{ "loss", "draw", "win", "unknown" };
pub const Kind = enum { other, hung_piece, missed_capture, missed_mate, allowed_mate, bad_capture };

/// What a flagged move teaches: its kind, or for `.other` the tactic behind
/// it (one the player allowed or one they missed), a deeper combination, or
/// a positional mistake. The JSON report, the coach and the scripts group
/// mistakes by this.
pub const Lesson = enum {
    hung_piece,
    missed_capture,
    bad_capture,
    allowed_mate,
    missed_mate,
    allowed_fork,
    missed_fork,
    allowed_pin,
    missed_pin,
    allowed_skewer,
    missed_skewer,
    allowed_discovery,
    missed_discovery,
    trapped_piece,
    missed_trap,
    allowed_removal,
    missed_removal,
    deep_tactic,
    king_safety,
    positional,
};

pub const piece_names = [6][]const u8{ "pawn", "knight", "bishop", "rook", "queen", "king" };
const see_value = [6]i32{ 100, 300, 300, 500, 900, 0 };

/// Winning chances (0..100) for the side with score `cp` (Lichess formula).
pub fn winPct(cp: i32) f64 {
    const c: f64 = @floatFromInt(std.math.clamp(cp, -1500, 1500));
    return 50 + 50 * (2 / (1 + @exp(-0.00368208 * c)) - 1);
}

fn moveAccuracy(drop: f64) f64 {
    return std.math.clamp(103.1668 * @exp(-0.04354 * drop) - 3.1669, 0, 100);
}

const Input = struct {
    headers: []pgn.Header,
    movetext: []const u8,

    fn header(in: *const Input, key: []const u8) []const u8 {
        for (in.headers) |h| if (std.mem.eql(u8, h.key, key)) return h.value;
        return "";
    }
};

const Collector = struct {
    gpa: std.mem.Allocator,
    user: []const u8,
    games: std.ArrayList(Input) = .empty,
    skipped: usize = 0,

    fn onGame(c: *Collector, g: *const pgn.Game) !void {
        const white = g.header("White") orelse "";
        const black = g.header("Black") orelse "";
        if (!g.isStandard() or !(std.ascii.eqlIgnoreCase(white, c.user) or std.ascii.eqlIgnoreCase(black, c.user))) {
            c.skipped += 1;
            return;
        }
        const headers = try c.gpa.alloc(pgn.Header, g.headers.len);
        for (g.headers, 0..) |h, i| headers[i] = .{ .key = try c.gpa.dupe(u8, h.key), .value = try c.gpa.dupe(u8, h.value) };
        try c.games.append(c.gpa, .{ .headers = headers, .movetext = try c.gpa.dupe(u8, g.movetext) });
    }
};

/// Search result for one position of a game.
pub const Eval = struct {
    score: i32, // side to move's point of view
    best: Move,
    pv: [8]Move,
    pv_len: usize,
};

/// Searches `p` (preceded by the positions with `keys`, for repetitions) for
/// about `nodes` nodes.
pub fn evalPosition(s: *search.Searcher, p: *const Position, keys: []const u64, nodes: u64) Eval {
    var list = movegen.MoveList{};
    movegen.generate(p, &list, .all);
    if (list.len == 0) return .{ .score = if (p.inCheck()) -search.MATE else 0, .best = Move.none, .pv = undefined, .pv_len = 0 };
    s.setPosition(p, keys);
    const r = s.search(.{ .soft_nodes = nodes, .nodes = nodes * 3 });
    var e = Eval{ .score = r.score, .best = r.move, .pv = undefined, .pv_len = @min(s.pv_len[0], 8) };
    for (0..e.pv_len) |k| e.pv[k] = s.pv[0][k];
    if (e.pv_len == 0 or !e.pv[0].eql(r.move)) {
        e.pv[0] = r.move;
        e.pv_len = 1;
    }
    return e;
}

/// `by_eval`: the class comes from the eval drop, not the winning chances.
pub const Grade = struct { drop: f64, cls: Class, by_eval: bool = false };

/// Eval thrown away (centipawns) that is a mistake or a blunder however far
/// ahead or behind the mover is: there the winning chances hardly move (a
/// queen hung at +16 costs about 4%), but it's still a piece left hanging.
const MISTAKE_CP = 300;
const BLUNDER_CP = 600;

/// How much a move cost the mover in winning chances, from the scores before
/// it (mover's view) and after it (opponent's view).
pub fn grade(before: i32, after_opp: i32) Grade {
    const drop = @max(0, winPct(before) - winPct(-after_opp));
    const cls: Class = if (drop >= 30) .blunder else if (drop >= 20) .mistake else if (drop >= 10) .inaccuracy else .good;
    if (@abs(before) < search.MATE_BOUND and @abs(after_opp) < search.MATE_BOUND) {
        const loss = before + after_opp;
        const by: Class = if (loss >= BLUNDER_CP) .blunder else if (loss >= MISTAKE_CP) .mistake else .good;
        if (@intFromEnum(by) > @intFromEnum(cls)) return .{ .drop = drop, .cls = by, .by_eval = true };
    }
    return .{ .drop = drop, .cls = cls };
}

test "grade: a hung queen far ahead is still a blunder" {
    // 18. Bd4?? leaving the queen to Nxa7: +16.80 -> +8.45.
    const g = grade(1680, -845);
    try std.testing.expect(g.cls == .blunder and g.by_eval);
    try std.testing.expect(grade(1680, -1550).cls == .good);
    try std.testing.expect(grade(200, -100).cls == .good);
    try std.testing.expect(grade(150, 250).cls == .blunder and !grade(150, 250).by_eval);
}

const Flag = struct {
    ply: usize,
    cls: Class,
    label: Label,
    drop: f64,
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Output,
    net: ?*const nnue.Network,
    user: []const u8,
    nodes: u64,
    inputs: []const Input,
    json: []std.ArrayList(u8),
    pgn_text: []std.ArrayList(u8),
    summaries: []Summary,
    next: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),
    mutex: Io.Mutex = .init,
};

const Summary = struct {
    analysed: bool = false,
    result: u8 = 1, // 0 loss, 1 draw, 2 win (user's point of view), 3 unknown ("*": unfinished, or a game against zchess the engine never saw end)
    accuracy: f64 = 0,
    counts: [4]u32 = .{ 0, 0, 0, 0 },
    kinds: [6]u32 = .{0} ** 6,
    lessons: [n_lessons]u32 = .{0} ** n_lessons,
};

const n_lessons = std.enums.values(Lesson).len;

fn userIsWhite(in: *const Input, user: []const u8) bool {
    return std.ascii.eqlIgnoreCase(in.header("White"), user);
}

fn phaseOf(pos: *const Position, ply: usize) []const u8 {
    if (ply < 20) return "opening";
    const npm = bb.popcount(pos.pieces[bb.KNIGHT] | pos.pieces[bb.BISHOP]) +
        2 * bb.popcount(pos.pieces[bb.ROOK]) + 4 * bb.popcount(pos.pieces[bb.QUEEN]);
    return if (npm <= 8) "endgame" else "middlegame";
}

pub fn victimOf(pos: *const Position, m: Move) ?bb.PieceType {
    if (m.flag() == Move.EP_CAPTURE) return bb.PAWN;
    if (!m.isCapture()) return null;
    return bb.pieceType(pos.board[m.to()]);
}

pub const Label = struct {
    kind: Kind = .other,
    piece: ?bb.PieceType = null,
    /// A second lesson in the same move: "and left your knight hanging".
    also_hung: ?bb.PieceType = null,
    /// The tactic behind it (see tactics.zig), and whether it is the
    /// opponent's reply (against the player) or a move the player missed.
    tactic: tactics.Hit = .{},
    against: bool = true,
    /// The punishing line wins material even though no tactic was named,
    /// or it is a run of checks against the player's king.
    loses_material: bool = false,
    king_attack: bool = false,
    /// SAN of the tactic's key move and, when that comes later in the line
    /// (`tactic.at` > 0), of the moves leading to it.
    san: Sans = .{},

    pub fn keySan(l: *const Label) []const u8 {
        return l.san.key[0..l.san.key_len];
    }
    pub fn leadSan(l: *const Label) []const u8 {
        return l.san.lead[0..l.san.lead_len];
    }

    pub fn lesson(l: Label) Lesson {
        return switch (l.kind) {
            .hung_piece => .hung_piece,
            .missed_capture => .missed_capture,
            .bad_capture => .bad_capture,
            .allowed_mate => .allowed_mate,
            .missed_mate => .missed_mate,
            .other => switch (l.tactic.motif) {
                .fork => if (l.against) .allowed_fork else .missed_fork,
                .pin => if (l.against) .allowed_pin else .missed_pin,
                .skewer => if (l.against) .allowed_skewer else .missed_skewer,
                .discovered_attack, .discovered_check, .double_check => if (l.against) .allowed_discovery else .missed_discovery,
                .trapped_piece => if (l.against) .trapped_piece else .missed_trap,
                .removed_defender => if (l.against) .allowed_removal else .missed_removal,
                .back_rank_mate, .smothered_mate => if (l.against) .allowed_mate else .missed_mate,
                .none => if (l.loses_material) .deep_tactic else if (l.king_attack) .king_safety else .positional,
            },
        };
    }
};

/// Material of side `c` in pawns (king excluded).
fn material(p: *const Position, c: bb.Color) i32 {
    var total: i32 = 0;
    for (0..5) |pt| total += @as(i32, @intCast(bb.popcount(p.pieces[pt] & p.colors[c]))) * @divTrunc(see_value[pt], 100);
    return total;
}

/// Material (pawns) the side to move in `p` gains over the line `pv`.
fn lineGain(p: *const Position, pv: []const Move) i32 {
    const us = p.side;
    var q = p.*;
    for (pv) |m| {
        if (m.data == 0) break;
        q = q.makeMove(m);
    }
    return (material(&q, us) - material(&q, us ^ 1)) - (material(p, us) - material(p, us ^ 1));
}

/// Plain-language label for a flagged move. When the move both missed a win of
/// material and left something hanging, the bigger swing leads and the other
/// is mentioned too.
/// A capture counts as winning material when it nets at least this much
/// (centipawns, by static exchange), even if the capturing piece is lost back.
const min_gain = 200;

pub fn classifyKind(positions: []const Position, evals: []const Eval, moves: []const Move, i: usize) Label {
    var l = classifyMaterial(positions, evals, moves, i);
    const reply = &evals[i + 1];
    const best = &evals[i];
    const against = findInLine(&positions[i + 1], reply.pv[0..reply.pv_len], 4);
    const missed = if (best.best.eql(moves[i])) Found{} else findInLine(&positions[i], best.pv[0..best.pv_len], 2);
    const is_mate = struct {
        fn f(h: tactics.Hit) bool {
            return h.motif == .back_rank_mate or h.motif == .smothered_mate;
        }
    }.f;
    var use: ?*const Found = null;
    switch (l.kind) {
        .allowed_mate => if (is_mate(against.hit)) {
            use = &against;
        },
        .missed_mate => if (is_mate(missed.hit)) {
            use = &missed;
        },
        else => if (against.hit.motif != .none) {
            use = &against;
        } else if (missed.hit.motif != .none) {
            use = &missed;
        },
    }
    if (use) |f| {
        l.tactic = f.hit;
        l.against = f == &against;
        l.san = f.san;
    }
    if (l.kind == .other and l.tactic.motif == .none) {
        const pv = reply.pv[0..reply.pv_len];
        l.loses_material = lineGain(&positions[i + 1], pv) >= 2;
        l.king_attack = kingHunt(&positions[i + 1], pv);
    }
    return l;
}

pub const Sans = struct {
    key: [10]u8 = undefined,
    key_len: u8 = 0,
    lead: [48]u8 = undefined,
    lead_len: u8 = 0,
};

/// A tactic in a line, and the SAN of its key move (and of the moves before
/// it when the tactic comes later).
const Found = struct {
    hit: tactics.Hit = .{},
    san: Sans = .{},
};

/// The first tactic among the moving side's moves of `pv` up to ply
/// `max_ply` (a check or capture often comes first, the fork after it).
/// Deep in the line only the clearest motifs count.
fn findInLine(start: *const Position, pv: []const Move, max_ply: usize) Found {
    var f = Found{};
    var p = start.*;
    var k: usize = 0;
    while (k < pv.len and k <= max_ply) : (k += 1) {
        if (pv[k].data == 0) break;
        if (k % 2 == 0) {
            const h = tactics.find(&p, pv[k..]);
            const clear = switch (h.motif) {
                .fork, .skewer, .double_check, .discovered_check, .back_rank_mate, .smothered_mate => true,
                else => false,
            };
            if (h.motif != .none and (k <= 2 or clear)) {
                f.hit = h;
                f.hit.at = @intCast(k);
                var b: [16]u8 = undefined;
                const key = play.san(&p, pv[k], &b);
                f.san.key_len = @intCast(@min(key.len, f.san.key.len));
                @memcpy(f.san.key[0..f.san.key_len], key[0..f.san.key_len]);
                var w: Io.Writer = .fixed(&f.san.lead);
                var q = start.*;
                for (pv[0..k], 0..) |m, j| {
                    w.print("{s}{s}", .{ if (j > 0) " " else "", play.san(&q, m, &b) }) catch break;
                    q = q.makeMove(m);
                }
                f.san.lead_len = @intCast(w.buffered().len);
                return f;
            }
        }
        p = p.makeMove(pv[k]);
    }
    return f;
}

/// Whether the line `pv` (the opponent to move in `p`) chases the player's
/// king: two checks, or a check that forces it to move.
fn kingHunt(p: *const Position, pv: []const Move) bool {
    var q = p.*;
    var checks: u32 = 0;
    for (pv, 0..) |m, k| {
        if (m.data == 0) break;
        if (k % 2 == 1 and q.inCheck() and bb.pieceType(q.board[m.from()]) == bb.KING and !m.isCastle()) return true;
        q = q.makeMove(m);
        if (k % 2 == 0 and q.inCheck()) checks += 1;
    }
    return checks >= 2;
}

fn classifyMaterial(positions: []const Position, evals: []const Eval, moves: []const Move, i: usize) Label {
    const before = evals[i].score; // mover's view, before the move
    const after_opp = evals[i + 1].score; // opponent's view, after the move
    if (after_opp >= search.MATE_BOUND and before > -search.MATE_BOUND) return .{ .kind = .allowed_mate };
    if (before >= search.MATE_BOUND and -after_opp < search.MATE_BOUND) return .{ .kind = .missed_mate };

    // Opponent's best reply wins material: something was left hanging.
    var hung: ?bb.PieceType = null;
    const reply = evals[i + 1].best;
    if (reply.data != 0) {
        if (victimOf(&positions[i + 1], reply)) |v| {
            if (search.see(&positions[i + 1], reply, min_gain)) hung = v;
        }
    }
    // The best move would have won material that wasn't taken.
    var missed: ?bb.PieceType = null;
    const best = evals[i].best;
    if (!best.eql(moves[i])) {
        if (victimOf(&positions[i], best)) |v| {
            if (search.see(&positions[i], best, min_gain)) missed = v;
        }
    }
    if (missed) |m| {
        if (hung) |h| {
            if (see_value[m] > see_value[h]) return .{ .kind = .missed_capture, .piece = m, .also_hung = h };
            return .{ .kind = .hung_piece, .piece = h };
        }
        return .{ .kind = .missed_capture, .piece = m };
    }
    if (hung == null) hung = takenLater(&positions[i + 1], evals[i + 1].pv[0..evals[i + 1].pv_len]);
    if (hung) |h| return .{ .kind = .hung_piece, .piece = h };
    if (moves[i].isCapture() and !search.see(&positions[i], moves[i], 0)) return .{ .kind = .bad_capture, .piece = victimOf(&positions[i], moves[i]) };
    return .{};
}

/// A loose piece of the player's (attacked, and undefended or attacked by
/// something cheaper) that the opponent's line `pv` from `p` takes within its
/// first three moves, after an in-between move such as a check.
fn takenLater(p: *const Position, pv: []const Move) ?bb.PieceType {
    const loose = tactics.loosePieces(p, p.side ^ 1);
    if (loose == 0) return null;
    var q = p.*;
    for (pv[0..@min(pv.len, 5)], 0..) |m, k| {
        if (m.data == 0) break;
        if (k % 2 == 0 and m.isCapture() and loose & bb.bit(m.to()) != 0 and bb.pieceColor(q.board[m.to()]) == p.side ^ 1)
            return bb.pieceType(q.board[m.to()]);
        q = q.makeMove(m);
    }
    return null;
}

/// Plain-language reason for a flagged move. `best_san` is the better move,
/// `reply_san` the opponent's best reply to the move played.
pub fn explain(l: Label, best_san: []const u8, reply_san: []const u8, buf: []u8) []const u8 {
    const p = if (l.piece) |pt| piece_names[pt] else "piece";
    const fmt = std.fmt.bufPrint;
    return switch (l.kind) {
        .allowed_mate => switch (l.tactic.motif) {
            .back_rank_mate => fmt(buf, "allowed a back-rank mate, starting with {s}", .{reply_san}) catch "allowed a back-rank mate",
            .smothered_mate => fmt(buf, "allowed a smothered mate, starting with {s}", .{reply_san}) catch "allowed a smothered mate",
            else => "allowed a forced checkmate",
        },
        .missed_mate => switch (l.tactic.motif) {
            .back_rank_mate => fmt(buf, "missed a back-rank mate starting with {s}", .{best_san}) catch "missed a back-rank mate",
            .smothered_mate => fmt(buf, "missed a smothered mate starting with {s}", .{best_san}) catch "missed a smothered mate",
            else => fmt(buf, "missed a forced checkmate starting with {s}", .{best_san}) catch "missed a forced checkmate",
        },
        .hung_piece => fmt(buf, "left your {s} hanging", .{p}) catch "left a piece hanging",
        .missed_capture => if (l.also_hung) |h|
            fmt(buf, "missed taking the {s} with {s}, and left your {s} hanging", .{ p, best_san, piece_names[h] }) catch "missed winning material"
        else
            fmt(buf, "missed taking the {s} with {s}", .{ p, best_san }) catch "missed winning material",
        .bad_capture => "captured into a losing exchange",
        .other => explainTactic(l, best_san, reply_san, buf),
    };
}

fn explainTactic(l: Label, best_san: []const u8, reply_san: []const u8, buf: []u8) []const u8 {
    const h = l.tactic;
    const t0 = if (h.targets[0]) |t| piece_names[t] else "piece";
    const t1 = if (h.targets[1]) |t| piece_names[t] else "piece";
    const by = if (h.by) |t| piece_names[t] else "piece";
    const a = l.against;
    const your = if (a) "your" else "the";
    const verb = if (a) "allowed" else "missed";
    // "after Bxf2+, Nf2 ..." when the tactic comes later in the line.
    var mb: [72]u8 = undefined;
    const key = if (l.keySan().len > 0) l.keySan() else if (a) reply_san else best_san;
    const mv = if (h.at > 0) std.fmt.bufPrint(&mb, "after {s}, {s}", .{ l.leadSan(), key }) catch key else key;
    var w: Io.Writer = .fixed(buf);
    (switch (h.motif) {
        .fork => if (a)
            w.print("walked into a {s} fork: {s} hits your {s} and {s}", .{ by, mv, t0, t1 })
        else
            w.print("missed a {s} fork: {s} hits the {s} and {s}", .{ by, mv, t0, t1 }),
        .pin => w.print("{s} a pin: {s} pins {s} {s} to {s} {s}", .{ verb, mv, your, t0, your, t1 }),
        .skewer => w.print("{s} a skewer: {s} attacks {s} {s} and wins the {s} behind it", .{ verb, mv, your, t0, t1 }),
        .discovered_check => if (h.targets[0]) |_|
            w.print("{s} a discovered check: {s} uncovers check, and the {s} wins {s} {s}", .{ verb, mv, by, your, t0 })
        else
            w.print("{s} a discovered check: {s}", .{ verb, mv }),
        .double_check => w.print("{s} a double check: {s}", .{ verb, mv }),
        .discovered_attack => if (h.targets[1]) |t|
            w.print("{s} a discovered attack: {s} hits {s} {s} and uncovers an attack on {s} {s}", .{ verb, mv, your, piece_names[t], your, t0 })
        else
            w.print("{s} a discovered attack: {s} uncovers an attack on {s} {s}", .{ verb, mv, your, t0 }),
        .trapped_piece => if (a)
            w.print("let your {s} get trapped: {s} attacks it and it has no safe square", .{ t0, mv })
        else
            w.print("missed trapping the {s}: {s}", .{ t0, mv }),
        .removed_defender => w.print("{s} a removal of the defender: {s} takes the piece guarding {s} {s}", .{ verb, mv, your, t0 }),
        .back_rank_mate => w.print("{s} a back-rank mate: {s}", .{ verb, mv }),
        .smothered_mate => w.print("{s} a smothered mate: {s}", .{ verb, mv }),
        .none => if (l.loses_material)
            w.print("walked into a combination that wins material, starting with {s}", .{reply_san})
        else if (l.king_attack)
            w.print("let your opponent go after your king, starting with {s}", .{reply_san})
        else
            w.writeAll("gave up ground: no material goes straight away, but your position gets worse"),
    }) catch return "walked into a tactic";
    return w.buffered();
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...9, 11...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Score from white's point of view, for graphs: centipawns clamped to
/// +-1500, mates mapped to +-1500.
fn whiteCp(score: i32, side: bb.Color) i32 {
    const s = std.math.clamp(score, -1500, 1500);
    return if (side == bb.WHITE) s else -s;
}

/// SAN of `m` in `p`, or "" for no move.
fn sanOrEmpty(p: *const Position, m: Move, buf: *[16]u8) []const u8 {
    return if (m.data == 0) "" else play.san(p, m, buf);
}

fn pgnEval(score: i32, side: bb.Color, buf: []u8) []const u8 {
    const white = if (side == bb.WHITE) score else -score;
    if (@abs(white) >= search.MATE_BOUND) {
        const moves = @divTrunc(search.MATE - @as(i32, @intCast(@abs(white))) + 1, 2);
        return std.fmt.bufPrint(buf, "#{s}{d}", .{ if (white < 0) "-" else "", moves }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>2}", .{ if (white < 0) "-" else "", @abs(white) / 100, @abs(white) % 100 }) catch "";
}

/// Blunder-check drills start after this many plies (the first moves are
/// rarely in doubt).
const CHECK_FROM_PLY = 6;

/// The player's sound moves that still leave something attacked, as JSON for
/// the blunder-check drill, where they are mixed with the moves that lost
/// material: is this move safe? Kept when every attacked piece (not pawns or
/// the king) is defended and only attacked by pieces worth as much or more,
/// so counting attackers and defenders shows why it is safe.
fn writeChecks(w: *Io.Writer, positions: []const Position, moves: []const Move, flags: []const Flag, user: bb.Color) !void {
    try w.writeByte('[');
    var first = true;
    var fi: usize = 0;
    for (moves, 0..) |m, i| {
        while (fi < flags.len and flags[fi].ply < i) fi += 1;
        if (positions[i].side != user or i < CHECK_FROM_PLY) continue;
        if (fi < flags.len and flags[fi].ply == i) continue;
        const after = &positions[i + 1];
        if (after.inCheck()) continue;
        if (tactics.loosePieces(after, user) != 0) continue;
        const occ = after.occupied();
        var attacked: u64 = 0;
        var pieces = after.colors[user] & ~after.pieces[bb.PAWN] & ~after.pieces[bb.KING];
        while (pieces != 0) {
            const sq = bb.popLsb(&pieces);
            if (after.attackersTo(sq, occ) & after.colors[user ^ 1] != 0) attacked |= bb.bit(sq);
        }
        if (attacked == 0) continue;
        var fen_buf: [128]u8 = undefined;
        var ub: [5]u8 = undefined;
        var sb: [16]u8 = undefined;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"ply\":{d},\"move_no\":{d},\"san\":", .{ i, positions[i].fullmove });
        try writeJsonString(w, play.san(&positions[i], m, &sb));
        try w.writeAll(",\"fen\":");
        try writeJsonString(w, positions[i].toFen(&fen_buf));
        try w.writeAll(",\"uci\":");
        try writeJsonString(w, m.toUci(&ub));
        try w.writeAll(",\"attacked\":[");
        var a = attacked;
        var first_a = true;
        while (a != 0) {
            const sq = bb.popLsb(&a);
            const attackers = after.attackersTo(sq, occ) & after.colors[user ^ 1];
            const defenders = after.attackersTo(sq, occ) & after.colors[user] & ~bb.bit(sq);
            const name = bb.squareName(sq);
            if (!first_a) try w.writeByte(',');
            first_a = false;
            try w.print("{{\"sq\":\"{s}\",\"piece\":\"{s}\",\"by\":\"{s}\",\"attackers\":{d},\"defenders\":{d}}}", .{
                &name, piece_names[bb.pieceType(after.board[sq])], piece_names[tactics.cheapestType(after, attackers)], @popCount(attackers), @popCount(defenders),
            });
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// Book moves listed for an opening drill: at least this share (percent).
const DRILL_MIN_PCT = 5;
/// Opening drills only from the first moves.
const DRILL_PLIES = 40;

/// The player's moves while the game was still in opening theory (strong
/// players' moves, see openings.zig), as JSON for opening drills: the
/// position, what they played and what strong players play there. Ends with
/// the move where they left theory (`exit`), or where the opponent did.
fn writeOpeningMoves(w: *Io.Writer, positions: []const Position, moves: []const Move, evals: []const Eval, user: bb.Color) !void {
    try w.writeByte('[');
    defer w.writeByte(']') catch {};
    const book = openings.Book.embeddedBook() orelse return;
    var named: ?openings.Name = null;
    var first = true;
    for (moves[0..@min(moves.len, DRILL_PLIES)], 0..) |m, i| {
        const p = &positions[i];
        if (book.name(p.key)) |n| named = n;
        const ms = book.moves(p.key);
        const total = ms.total();
        if (total < coach.MIN_THEORY) return;
        var mine: u64 = 0;
        for (0..ms.len()) |k| {
            const e = ms.get(k);
            if (e.move.eql(m)) {
                mine = e.games();
                break;
            }
        }
        const exit = mine * 100 < coach.MIN_BOOK_PCT * total;
        if (p.side != user) {
            if (exit) return;
            continue;
        }

        var sb: [16]u8 = undefined;
        var ub: [5]u8 = undefined;
        var fen_buf: [128]u8 = undefined;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"ply\":{d},\"move_no\":{d},\"exit\":{},\"fen\":", .{ i, p.fullmove, exit });
        try writeJsonString(w, p.toFen(&fen_buf));
        try w.writeAll(",\"played\":");
        try writeJsonString(w, play.san(p, m, &sb));
        try w.writeAll(",\"played_uci\":");
        try writeJsonString(w, m.toUci(&ub));
        // What the move cost, in winning chances.
        try w.print(",\"played_pct\":{d:.1},\"drop\":{d:.1},\"total\":{d},\"book\":[", .{ pctOf(mine, total), grade(evals[i].score, evals[i + 1].score).drop, total });
        for (0..ms.len()) |k| {
            const e = ms.get(k);
            if (k > 0 and e.games() * 100 < DRILL_MIN_PCT * total) break;
            if (k > 0) try w.writeByte(',');
            try w.writeAll("{\"san\":");
            try writeJsonString(w, play.san(p, e.move, &sb));
            try w.writeAll(",\"uci\":");
            try writeJsonString(w, e.move.toUci(&ub));
            try w.print(",\"pct\":{d:.1}}}", .{pctOf(e.games(), total)});
        }
        try w.writeAll("],\"opening\":");
        try writeJsonString(w, if (named) |n| n.name else "");
        try w.writeAll(",\"eco\":");
        try writeJsonString(w, if (named) |n| n.eco else "");
        try w.writeByte('}');
        if (exit) return;
    }
}

fn pctOf(n: u64, total: u64) f64 {
    return @as(f64, @floatFromInt(n)) * 100 / @as(f64, @floatFromInt(@max(total, 1)));
}

fn analyse(ctx: *Ctx, s: *search.Searcher, gi: usize) !void {
    const in = &ctx.inputs[gi];
    const gpa = ctx.gpa;
    var positions: std.ArrayList(Position) = .empty;
    defer positions.deinit(gpa);
    var moves: std.ArrayList(Move) = .empty;
    defer moves.deinit(gpa);
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(gpa);

    var pos = Position.startpos();
    try positions.append(gpa, pos);
    var it = pgn.SanIterator.init(in.movetext);
    while (it.next()) |tok| {
        const m = play.parseMove(&pos, tok) orelse break;
        try moves.append(gpa, m);
        pos = pos.makeMove(m);
        try positions.append(gpa, pos);
    }
    const n = moves.items.len;
    const user_white = userIsWhite(in, ctx.user);
    const user_color: bb.Color = if (user_white) bb.WHITE else bb.BLACK;

    // Search every position (the final one too, to judge the last move).
    const evals = try gpa.alloc(Eval, n + 1);
    defer gpa.free(evals);
    s.tt.clear();
    s.clearHistory();
    for (positions.items, 0..) |*p, i| {
        evals[i] = evalPosition(s, p, keys.items, ctx.nodes);
        try keys.append(gpa, p.key);
    }

    // Judge the user's moves.
    var flags: std.ArrayList(Flag) = .empty;
    defer flags.deinit(gpa);
    var sum = Summary{ .analysed = true };
    var acc_sum: f64 = 0;
    var user_moves: usize = 0;
    for (0..n) |i| {
        if (positions.items[i].side != user_color) continue;
        const g = grade(evals[i].score, evals[i + 1].score);
        const drop = g.drop;
        const cls = g.cls;
        acc_sum += moveAccuracy(drop);
        user_moves += 1;
        if (cls == .good) continue;
        const label = classifyKind(positions.items, evals, moves.items, i);
        try flags.append(gpa, .{ .ply = i, .cls = cls, .label = label, .drop = drop });
        sum.counts[@intFromEnum(cls)] += 1;
        if (cls != .inaccuracy) {
            sum.kinds[@intFromEnum(label.kind)] += 1;
            sum.lessons[@intFromEnum(label.lesson())] += 1;
        }
    }
    sum.accuracy = if (user_moves > 0) acc_sum / @as(f64, @floatFromInt(user_moves)) else 0;
    const res = in.header("Result");
    sum.result = if (std.mem.eql(u8, res, "1/2-1/2")) 1 else if (std.mem.eql(u8, res, if (user_white) "1-0" else "0-1")) 2 else if (std.mem.eql(u8, res, "*") or res.len == 0) 3 else 0;

    // JSON fragment.
    var jw: Io.Writer.Allocating = .init(gpa);
    defer jw.deinit();
    const w = &jw.writer;
    try w.writeAll("{");
    inline for (.{ .{ "link", "Link" }, .{ "date", "Date" }, .{ "white", "White" }, .{ "black", "Black" }, .{ "white_elo", "WhiteElo" }, .{ "black_elo", "BlackElo" }, .{ "pgn_result", "Result" }, .{ "termination", "Termination" }, .{ "time_control", "TimeControl" }, .{ "eco", "ECO" }, .{ "opening_url", "ECOUrl" } }) |kv| {
        try w.print("\"{s}\":", .{kv[0]});
        try writeJsonString(w, in.header(kv[1]));
        try w.writeAll(",");
    }
    try w.print("\"color\":\"{s}\",\"result\":\"{s}\",\"accuracy\":{d:.1},\"counts\":{{\"inaccuracy\":{d},\"mistake\":{d},\"blunder\":{d}}},", .{
        if (user_white) "white" else "black", result_names[sum.result], sum.accuracy, sum.counts[1], sum.counts[2], sum.counts[3],
    });
    try w.writeAll("\"moves\":[");
    for (moves.items, 0..) |m, i| {
        var sb: [16]u8 = undefined;
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, play.san(&positions.items[i], m, &sb));
    }
    try w.writeAll("],\"evals\":[");
    for (evals, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{whiteCp(e.score, positions.items[i].side)});
    }
    try w.writeAll("],\"flags\":[");
    for (flags.items, 0..) |f, fi| {
        const p = &positions.items[f.ply];
        var sb: [16]u8 = undefined;
        var fen_buf: [128]u8 = undefined;
        var eb: [192]u8 = undefined;
        var bsb: [16]u8 = undefined;
        if (fi > 0) try w.writeByte(',');
        try w.print("{{\"ply\":{d},\"move_no\":{d},\"san\":", .{ f.ply, p.fullmove });
        try writeJsonString(w, play.san(p, moves.items[f.ply], &sb));
        try w.print(",\"cls\":\"{s}\",\"kind\":\"{s}\",\"piece\":\"{s}\",\"best\":", .{ @tagName(f.cls), @tagName(f.label.kind), if (f.label.piece) |pt| piece_names[pt] else "" });
        try writeJsonString(w, play.san(p, evals[f.ply].best, &bsb));
        try w.writeAll(",\"explain\":");
        var rsb: [16]u8 = undefined;
        const reply_san = sanOrEmpty(&positions.items[f.ply + 1], evals[f.ply + 1].best, &rsb);
        try writeJsonString(w, explain(f.label, play.san(p, evals[f.ply].best, &bsb), reply_san, &eb));
        try w.writeAll(",\"reply\":");
        try writeJsonString(w, reply_san);
        try w.print(",\"lesson\":\"{s}\",\"motif\":\"{s}\",\"against\":{},\"tactic_targets\":[", .{
            @tagName(f.label.lesson()), @tagName(f.label.tactic.motif), f.label.against,
        });
        var first_t = true;
        for (f.label.tactic.targets) |t| if (t) |pt| {
            if (!first_t) try w.writeByte(',');
            first_t = false;
            try w.print("\"{s}\"", .{piece_names[pt]});
        };
        try w.writeByte(']');
        try w.print(",\"drop\":{d:.1},\"win_before\":{d:.1},\"win_after\":{d:.1},\"phase\":\"{s}\",\"fen\":", .{
            f.drop, winPct(evals[f.ply].score), winPct(-evals[f.ply + 1].score), phaseOf(p, f.ply),
        });
        try writeJsonString(w, p.toFen(&fen_buf));
        // Squares for click-to-move puzzles, and the position after the move.
        var ub: [5]u8 = undefined;
        try w.writeAll(",\"played_uci\":");
        try writeJsonString(w, moves.items[f.ply].toUci(&ub));
        try w.writeAll(",\"best_uci\":");
        try writeJsonString(w, evals[f.ply].best.toUci(&ub));
        try w.writeAll(",\"reply_uci\":");
        try writeJsonString(w, evals[f.ply + 1].best.toUci(&ub));
        try w.writeAll(",\"fen_after\":");
        try writeJsonString(w, positions.items[f.ply + 1].toFen(&fen_buf));
        // For Lichess-style puzzles: the position before the opponent's last move,
        // and that move (puzzles start by playing it).
        if (f.ply > 0) {
            try w.writeAll(",\"setup_fen\":");
            try writeJsonString(w, positions.items[f.ply - 1].toFen(&fen_buf));
            try w.writeAll(",\"setup_uci\":");
            try writeJsonString(w, moves.items[f.ply - 1].toUci(&ub));
        }
        // The best line and the punishing line in UCI.
        inline for (.{ .{ "best_line_uci", f.ply }, .{ "refutation_uci", f.ply + 1 } }) |spec| {
            try w.print(",\"{s}\":[", .{spec[0]});
            for (evals[spec[1]].pv[0..evals[spec[1]].pv_len], 0..) |m, k| {
                var mb: [5]u8 = undefined;
                if (k > 0) try w.writeByte(',');
                try writeJsonString(w, m.toUci(&mb));
            }
            try w.writeByte(']');
        }
        // Best line from this position, and the opponent's punishing reply.
        try w.writeAll(",\"best_line\":[");
        var lp = p.*;
        for (evals[f.ply].pv[0..evals[f.ply].pv_len], 0..) |m, k| {
            var lb: [16]u8 = undefined;
            if (k > 0) try w.writeByte(',');
            try writeJsonString(w, play.san(&lp, m, &lb));
            lp = lp.makeMove(m);
        }
        try w.writeAll("],\"refutation\":[");
        lp = positions.items[f.ply + 1];
        for (evals[f.ply + 1].pv[0..evals[f.ply + 1].pv_len], 0..) |m, k| {
            var lb: [16]u8 = undefined;
            if (k > 0) try w.writeByte(',');
            try writeJsonString(w, play.san(&lp, m, &lb));
            lp = lp.makeMove(m);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"opening_moves\":");
    try writeOpeningMoves(w, positions.items, moves.items, evals, user_color);
    try w.writeAll(",\"checks\":");
    try writeChecks(w, positions.items, moves.items, flags.items, user_color);
    try w.writeByte('}');
    try ctx.json[gi].appendSlice(gpa, jw.written());

    // Annotated PGN.
    var pw: Io.Writer.Allocating = .init(gpa);
    defer pw.deinit();
    const o = &pw.writer;
    for (in.headers) |h| try o.print("[{s} \"{s}\"]\n", .{ h.key, h.value });
    try o.print("[Annotator \"zchess review ({d} nodes/position)\"]\n\n", .{ctx.nodes});
    // Game summary: shown by GUIs before the first move.
    try o.print("{{zchess review for {s}: accuracy {d:.0}%, {d} blunders, {d} mistakes, {d} inaccuracies.", .{
        ctx.user, sum.accuracy, sum.counts[3], sum.counts[2], sum.counts[1],
    });
    var worst: ?usize = null;
    for (flags.items, 0..) |f, k| {
        if (worst == null or f.drop > flags.items[worst.?].drop) worst = k;
    }
    if (worst) |k| {
        const f = flags.items[k];
        const p = &positions.items[f.ply];
        var sb: [16]u8 = undefined;
        var bsb: [16]u8 = undefined;
        var xb: [192]u8 = undefined;
        var rsb: [16]u8 = undefined;
        try o.print(" Biggest moment: {d}{s} {s}, which {s}.", .{
            p.fullmove, if (p.side == bb.WHITE) "." else "...", play.san(p, moves.items[f.ply], &sb), explain(f.label, play.san(p, evals[f.ply].best, &bsb), sanOrEmpty(&positions.items[f.ply + 1], evals[f.ply + 1].best, &rsb), &xb),
        });
    }
    try o.writeAll("}\n");
    var need_number = true;
    var fi: usize = 0;
    for (moves.items, 0..) |m, i| {
        const p = &positions.items[i];
        if (p.side == bb.WHITE) try o.print("{d}. ", .{p.fullmove}) else if (need_number) try o.print("{d}... ", .{p.fullmove});
        need_number = false;
        var sb: [16]u8 = undefined;
        try o.writeAll(play.san(p, m, &sb));
        var eb: [32]u8 = undefined;
        const flagged = fi < flags.items.len and flags.items[fi].ply == i;
        if (flagged) {
            const f = flags.items[fi];
            try o.writeAll(switch (f.cls) {
                .inaccuracy => " $6",
                .mistake => " $2",
                .blunder => " $4",
                .good => "",
            });
            var xb: [192]u8 = undefined;
            var bsb: [16]u8 = undefined;
            var bsb2: [16]u8 = undefined;
            var rsb: [16]u8 = undefined;
            const cls_name = ([_][]const u8{ "", "Inaccuracy", "Mistake", "Blunder" })[@intFromEnum(f.cls)];
            try o.print(" {{[%eval {s}] {s}: {s}. Best was {s}.}}", .{
                pgnEval(evals[i + 1].score, positions.items[i + 1].side, &eb), cls_name, explain(f.label, play.san(p, evals[i].best, &bsb2), sanOrEmpty(&positions.items[i + 1], evals[i + 1].best, &rsb), &xb), play.san(p, evals[i].best, &bsb),
            });
            // The better line as a variation.
            try o.writeAll(" (");
            var lp = p.*;
            for (evals[i].pv[0..evals[i].pv_len], 0..) |vm, k| {
                var vb: [16]u8 = undefined;
                if (lp.side == bb.WHITE) try o.print("{d}. ", .{lp.fullmove}) else if (k == 0) try o.print("{d}... ", .{lp.fullmove});
                try o.print("{s} ", .{play.san(&lp, vm, &vb)});
                lp = lp.makeMove(vm);
            }
            try o.writeAll(")");
            need_number = true;
            fi += 1;
        } else {
            try o.print(" {{[%eval {s}]}}", .{pgnEval(evals[i + 1].score, positions.items[i + 1].side, &eb)});
        }
        try o.writeByte(' ');
    }
    try o.print("{s}\n\n", .{in.header("Result")});
    try ctx.pgn_text[gi].appendSlice(gpa, pw.written());

    ctx.summaries[gi] = sum;
    const done = ctx.done.fetchAdd(1, .monotonic) + 1;
    const opp = if (user_white) in.header("Black") else in.header("White");
    ctx.out.print("[{d}/{d}] {s} vs {s}: {s}, accuracy {d:.0}%, {d} blunders, {d} mistakes, {d} inaccuracies\n", .{
        done, ctx.inputs.len, in.header("Date"), opp, result_names[sum.result], sum.accuracy, sum.counts[3], sum.counts[2], sum.counts[1],
    });
}

fn worker(ctx: *Ctx) void {
    workerImpl(ctx) catch |err| std.debug.print("review worker failed: {s}\n", .{@errorName(err)});
}

fn workerImpl(ctx: *Ctx) !void {
    var tt = try TT.init(ctx.gpa, 32);
    defer tt.deinit(ctx.gpa);
    var stop = std.atomic.Value(bool).init(false);
    const s = try search.Searcher.create(ctx.gpa, ctx.io, &tt, ctx.net, &stop);
    defer ctx.gpa.destroy(s);
    while (true) {
        const gi = ctx.next.fetchAdd(1, .monotonic);
        if (gi >= ctx.inputs.len) break;
        try analyse(ctx, s, gi);
    }
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var user: []const u8 = "";
    var json_path: []const u8 = "review.json";
    var pgn_path: []const u8 = "review.pgn";
    var nodes: u64 = 300_000;
    var threads: usize = std.Thread.getCpuCount() catch 4;
    var net_path: []const u8 = "";
    var inputs_paths: std.ArrayList([]const u8) = .empty;
    defer inputs_paths.deinit(gpa);
    while (p.next()) |a| {
        if (p.flag(a, "--user")) |v| user = v
        else if (p.flag(a, "--json")) |v| json_path = v
        else if (p.flag(a, "--pgn")) |v| pgn_path = v
        else if (p.int(u64, a, "--nodes")) |v| nodes = @max(v, 1000)
        else if (p.int(usize, a, "--threads")) |v| threads = @max(v, 1)
        else if (p.flag(a, "--net")) |v| net_path = v
        else if (a[0] != '-') try inputs_paths.append(gpa, a)
        else {
            out.print("{s}", .{help});
            return;
        }
    }
    if (user.len == 0 or inputs_paths.items.len == 0) {
        out.print("{s}", .{help});
        return;
    }

    var collector = Collector{ .gpa = gpa, .user = user };
    for (inputs_paths.items) |path| {
        const f = try Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var buf: [1 << 16]u8 = undefined;
        var fr = f.readerStreaming(io, &buf);
        try pgn.readGames(gpa, &fr.interface, &collector, Collector.onGame);
    }
    const games = collector.games.items;
    out.print("review: {d} games by {s} ({d} skipped), {d} nodes/position, {d} threads\n", .{ games.len, user, collector.skipped, nodes, threads });
    if (games.len == 0) return;

    const net = try cli.loadNet(gpa, io, net_path);
    var ctx = Ctx{
        .gpa = gpa,
        .io = io,
        .out = out,
        .net = net,
        .user = user,
        .nodes = nodes,
        .inputs = games,
        .json = try gpa.alloc(std.ArrayList(u8), games.len),
        .pgn_text = try gpa.alloc(std.ArrayList(u8), games.len),
        .summaries = try gpa.alloc(Summary, games.len),
    };
    for (ctx.json, ctx.pgn_text, ctx.summaries) |*j, *t, *sm| {
        j.* = .empty;
        t.* = .empty;
        sm.* = .{};
    }

    const n_threads = @min(threads, games.len);
    const handles = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(handles);
    for (handles) |*h| h.* = try std.Thread.spawn(.{}, worker, .{&ctx});
    for (handles) |h| h.join();

    // Totals.
    var total = Summary{};
    var analysed: usize = 0;
    var wdl = [4]u32{ 0, 0, 0, 0 };
    var acc: f64 = 0;
    for (ctx.summaries) |sm| {
        if (!sm.analysed) continue;
        analysed += 1;
        wdl[sm.result] += 1;
        acc += sm.accuracy;
        for (0..4) |k| total.counts[k] += sm.counts[k];
        for (0..6) |k| total.kinds[k] += sm.kinds[k];
        for (0..n_lessons) |k| total.lessons[k] += sm.lessons[k];
    }

    {
        const f = try Io.Dir.cwd().createFile(io, json_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var fw = f.writer(io, &buf);
        const w = &fw.interface;
        try w.writeAll("{\"user\":");
        try writeJsonString(w, user);
        try w.print(",\"nodes\":{d},\"games_analysed\":{d},\"wins\":{d},\"draws\":{d},\"losses\":{d},\"unknown\":{d},\"avg_accuracy\":{d:.1},", .{
            nodes, analysed, wdl[2], wdl[1], wdl[0], wdl[3], if (analysed > 0) acc / @as(f64, @floatFromInt(analysed)) else 0,
        });
        try w.print("\"totals\":{{\"inaccuracy\":{d},\"mistake\":{d},\"blunder\":{d}}},\"kinds\":{{", .{ total.counts[1], total.counts[2], total.counts[3] });
        for (std.enums.values(Kind), 0..) |k, ki| {
            if (ki > 0) try w.writeByte(',');
            try w.print("\"{s}\":{d}", .{ @tagName(k), total.kinds[@intFromEnum(k)] });
        }
        try w.writeAll("},\"lessons\":{");
        for (std.enums.values(Lesson), 0..) |k, ki| {
            if (ki > 0) try w.writeByte(',');
            try w.print("\"{s}\":{d}", .{ @tagName(k), total.lessons[@intFromEnum(k)] });
        }
        try w.writeAll("},\"games\":[");
        var first = true;
        for (ctx.json) |j| {
            if (j.items.len == 0) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll(j.items);
        }
        try w.writeAll("]}\n");
        try w.flush();
    }
    {
        const f = try Io.Dir.cwd().createFile(io, pgn_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var fw = f.writer(io, &buf);
        for (ctx.pgn_text) |t| try fw.interface.writeAll(t.items);
        try fw.interface.flush();
    }

    out.print("\n{d} games: +{d} ={d} -{d} ({d} without a result), average accuracy {d:.0}%\n", .{ analysed, wdl[2], wdl[1], wdl[0], wdl[3], if (analysed > 0) acc / @as(f64, @floatFromInt(analysed)) else 0 });
    out.print("{d} blunders, {d} mistakes, {d} inaccuracies\n", .{ total.counts[3], total.counts[2], total.counts[1] });
    // Mistakes and blunders by lesson, most common first.
    var order: [n_lessons]Lesson = undefined;
    @memcpy(&order, std.enums.values(Lesson));
    std.mem.sort(Lesson, &order, &total, struct {
        fn more(t: *const Summary, a: Lesson, b: Lesson) bool {
            return t.lessons[@intFromEnum(a)] > t.lessons[@intFromEnum(b)];
        }
    }.more);
    out.print("mistakes and blunders by lesson:", .{});
    for (order) |l| {
        const c = total.lessons[@intFromEnum(l)];
        if (c > 0) out.print(" {s} {d}", .{ @tagName(l), c });
    }
    out.print("\n", .{});
    out.print("-> {s}, {s}\n", .{ json_path, pgn_path });
}

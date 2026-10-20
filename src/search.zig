//! Principal variation search with iterative deepening, aspiration windows,
//! transposition table, null-move pruning, LMR, futility/LMP/SEE pruning and
//! quiescence search. Several Searchers sharing one TT give Lazy SMP.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const atk = @import("attacks.zig");
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const hce = @import("eval.zig");
const nnue = @import("nnue.zig");
const tt_mod = @import("tt.zig");
const Output = @import("output.zig").Output;

const Position = position.Position;
const Move = position.Move;
const MoveList = movegen.MoveList;
const TT = tt_mod.TT;

pub const MAX_PLY = 128;
pub const INF: i32 = 32001;
pub const MATE: i32 = 32000;
pub const MATE_BOUND: i32 = MATE - MAX_PLY;
const EVAL_NONE: i32 = -32002;
const MAX_KEYS = 512;
/// Continuation-history index (piece * 64 + to) of a null move or no move.
const NO_CONT: u16 = 0xFFFF;

pub const Limits = struct {
    depth: i32 = MAX_PLY - 1,
    /// Hard node cap; 0 = unlimited.
    nodes: u64 = 0,
    /// Don't start a new iteration after this many nodes; 0 = unlimited.
    soft_nodes: u64 = 0,
    /// Don't start a new iteration after this long; 0 = unlimited.
    soft_ms: i64 = 0,
    /// Abort the search after this long; 0 = unlimited.
    hard_ms: i64 = 0,
};

pub const MAX_MULTIPV = 16;

/// Lazy SMP depth skipping (Stockfish's pattern): helper `thread_index`
/// skips some iterations, so the helpers spread over depths instead of all
/// repeating the main thread's. The main thread and depth 1 never skip.
const skip_size = [20]i32{ 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4 };
const skip_phase = [20]i32{ 0, 1, 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 6, 7 };

fn skipDepth(thread_index: usize, depth: i32) bool {
    if (thread_index == 0 or depth <= 1) return false;
    const i = (thread_index - 1) % skip_size.len;
    return @mod(@divTrunc(depth + skip_phase[i], skip_size[i]), 2) != 0;
}

/// One reported line (MultiPV): its first move, score and principal variation.
pub const Line = struct {
    move: Move,
    score: i32,
    pv: [MAX_PLY]Move,
    pv_len: usize,
};

pub const Result = struct {
    move: Move,
    score: i32,
    depth: i32,
};

const see_value = [7]i32{ 100, 300, 300, 500, 900, 0, 0 };

var lmr_table: [64][64]u8 = undefined;
var lmr_ready = false;

fn initLmr() void {
    if (lmr_ready) return;
    lmr_ready = true;
    for (0..64) |d| {
        for (0..64) |m| {
            if (d == 0 or m == 0) {
                lmr_table[d][m] = 0;
                continue;
            }
            const r = 0.75 + @log(@as(f64, @floatFromInt(d))) * @log(@as(f64, @floatFromInt(m))) / 2.25;
            lmr_table[d][m] = @intFromFloat(@max(0, r));
        }
    }
}

/// Static exchange evaluation: does `m` win at least `threshold` material?
pub fn see(pos: *const Position, m: Move, threshold: i32) bool {
    if (m.isCastle() or m.isPromotion() or m.flag() == Move.EP_CAPTURE) return 0 >= threshold;
    const from = m.from();
    const to = m.to();
    var swap = see_value[if (pos.board[to] == bb.NO_PIECE) 6 else bb.pieceType(pos.board[to])] - threshold;
    if (swap < 0) return false;
    swap = see_value[bb.pieceType(pos.board[from])] - swap;
    if (swap <= 0) return true;

    var occ = pos.occupied() ^ bb.bit(from) ^ bb.bit(to);
    var stm = pos.side;
    var attackers = pos.attackersTo(to, occ);
    const bq = pos.pieces[bb.BISHOP] | pos.pieces[bb.QUEEN];
    const rq = pos.pieces[bb.ROOK] | pos.pieces[bb.QUEEN];
    var res: i32 = 1;
    while (true) {
        stm ^= 1;
        attackers &= occ;
        const stm_attackers = attackers & pos.colors[stm];
        if (stm_attackers == 0) break;
        res ^= 1;
        var b: u64 = undefined;
        if ((stm_attackers & pos.pieces[bb.PAWN]) != 0) {
            b = stm_attackers & pos.pieces[bb.PAWN];
            swap = see_value[0] - swap;
            if (swap < res) break;
            occ ^= b & (~b +% 1);
            attackers |= atk.bishop(to, occ) & bq;
        } else if ((stm_attackers & pos.pieces[bb.KNIGHT]) != 0) {
            b = stm_attackers & pos.pieces[bb.KNIGHT];
            swap = see_value[1] - swap;
            if (swap < res) break;
            occ ^= b & (~b +% 1);
        } else if ((stm_attackers & pos.pieces[bb.BISHOP]) != 0) {
            b = stm_attackers & pos.pieces[bb.BISHOP];
            swap = see_value[2] - swap;
            if (swap < res) break;
            occ ^= b & (~b +% 1);
            attackers |= atk.bishop(to, occ) & bq;
        } else if ((stm_attackers & pos.pieces[bb.ROOK]) != 0) {
            b = stm_attackers & pos.pieces[bb.ROOK];
            swap = see_value[3] - swap;
            if (swap < res) break;
            occ ^= b & (~b +% 1);
            attackers |= atk.rook(to, occ) & rq;
        } else if ((stm_attackers & pos.pieces[bb.QUEEN]) != 0) {
            b = stm_attackers & pos.pieces[bb.QUEEN];
            swap = see_value[4] - swap;
            if (swap < res) break;
            occ ^= b & (~b +% 1);
            attackers |= (atk.bishop(to, occ) & bq) | (atk.rook(to, occ) & rq);
        } else {
            // King: it may only capture if the opponent has no attackers left.
            return if (attackers & ~pos.colors[stm] != 0) res ^ 1 != 0 else res != 0;
        }
    }
    return res != 0;
}

/// Number of leading moves of `pv` that are legal when played from `root`.
fn legalPrefix(root: *const Position, pv: []const Move) usize {
    var pos = root.*;
    for (pv, 0..) |m, i| {
        var list = MoveList{};
        movegen.generate(&pos, &list, .all);
        var ok = false;
        for (list.slice()) |l| if (l.eql(m)) {
            ok = true;
            break;
        };
        if (!ok) return i;
        pos = pos.makeMove(m);
    }
    return pv.len;
}

inline fn scoreToTT(s: i32, ply: usize) i32 {
    const p: i32 = @intCast(ply);
    if (s >= MATE_BOUND) return s + p;
    if (s <= -MATE_BOUND) return s - p;
    return s;
}

inline fn scoreFromTT(s: i32, ply: usize) i32 {
    const p: i32 = @intCast(ply);
    if (s >= MATE_BOUND) return s - p;
    if (s <= -MATE_BOUND) return s + p;
    return s;
}

const ScoredMoves = struct {
    list: MoveList = .{},
    scores: [256]i32 = undefined,

    fn pick(self: *ScoredMoves, i: usize) Move {
        var best = i;
        for (i + 1..self.list.len) |j| {
            if (self.scores[j] > self.scores[best]) best = j;
        }
        if (best != i) {
            std.mem.swap(Move, &self.list.moves[i], &self.list.moves[best]);
            std.mem.swap(i32, &self.scores[i], &self.scores[best]);
        }
        return self.list.moves[i];
    }
};

pub const Searcher = struct {
    tt: *TT,
    net: ?*const nnue.Network,
    stop: *std.atomic.Value(bool),
    io: Io,
    /// Main thread prints UCI info lines; helpers stay silent.
    out: ?*Output = null,
    /// All searchers in this search (for total node counts). Empty = just self.
    peers: []const *Searcher = &.{},

    nodes: u64 = 0,
    shared_nodes: std.atomic.Value(u64) = .init(0),
    seldepth: usize = 0,
    limits: Limits = .{},
    start: Io.Timestamp = undefined,
    stopped: bool = false,
    /// Set by the UCI layer while pondering: time limits are ignored until
    /// ponderhit, after which they count from `clock_offset_ms`.
    pondering: ?*std.atomic.Value(bool) = null,
    clock_offset_ms: std.atomic.Value(i64) = .init(0),
    root_depth: i32 = 0,
    /// Lazy SMP: 0 for the main thread, 1.. for helpers (see `skipDepth`).
    thread_index: usize = 0,
    /// The result of this thread's last search (for `vote`).
    last: Result = .{ .move = Move.none, .score = 0, .depth = 0 },
    root_best: Move = Move.none,
    /// Number of lines to search and report (UCI MultiPV); 1 = normal search.
    multipv: usize = 1,
    /// Root moves skipped in the current search: lines already found this iteration.
    excluded: [MAX_MULTIPV]Move = undefined,
    n_excluded: usize = 0,
    /// Lines of the last completed iteration, best first.
    lines: [MAX_MULTIPV]Line = undefined,
    n_lines: usize = 0,

    root: Position = undefined,
    keys: [MAX_KEYS]u64 = undefined,
    key_len: usize = 0,

    history: [2][64][64]i32 = std.mem.zeroes([2][64][64]i32),
    /// Continuation history: [earlier move][this move], each as piece * 64 + to,
    /// for the moves one and two plies back. Zeroed in create (too big for a
    /// comptime default).
    cont_hist: [12 * 64][12 * 64]i16 = undefined,
    /// Continuation index of the move played at each ply.
    moved: [MAX_PLY + 2]u16 = undefined,
    killers: [MAX_PLY + 2][2]Move = undefined,
    evals: [MAX_PLY + 2]i32 = undefined,
    was_null: [MAX_PLY + 2]bool = undefined,
    /// Move skipped at each ply by a singular-extension verification search.
    singular: [MAX_PLY + 2]Move = undefined,
    pv: [MAX_PLY + 1][MAX_PLY + 1]Move = undefined,
    pv_len: [MAX_PLY + 1]usize = undefined,
    acc: [MAX_PLY + 2]nnue.Accumulator = undefined,

    pub fn create(gpa: std.mem.Allocator, io: Io, tt: *TT, net: ?*const nnue.Network, stop: *std.atomic.Value(bool)) !*Searcher {
        initLmr();
        const s = try gpa.create(Searcher);
        s.* = .{ .tt = tt, .net = net, .stop = stop, .io = io };
        s.clearHistory();
        return s;
    }

    pub fn clearHistory(self: *Searcher) void {
        self.history = std.mem.zeroes([2][64][64]i32);
        @memset(std.mem.sliceAsBytes(&self.cont_hist), 0);
    }

    inline fn contIndex(pos: *const Position, m: Move) u16 {
        return @as(u16, pos.board[m.from()]) * 64 + m.to();
    }

    /// Continuation-history entry of `m` after the move `back` plies before `ply`.
    inline fn contEntry(self: *Searcher, ply: usize, back: usize, idx: u16) ?*i16 {
        if (ply < back) return null;
        const prev = self.moved[ply - back];
        return if (prev == NO_CONT) null else &self.cont_hist[prev][idx];
    }

    /// Main plus continuation history of a quiet move.
    inline fn quietHistory(self: *Searcher, pos: *const Position, m: Move, ply: usize) i32 {
        const idx = contIndex(pos, m);
        var h = self.history[pos.side][m.from()][m.to()];
        if (self.contEntry(ply, 1, idx)) |e| h += e.*;
        if (self.contEntry(ply, 2, idx)) |e| h += e.*;
        return h;
    }

    fn updateQuietHistory(self: *Searcher, pos: *const Position, m: Move, ply: usize, bonus: i32) void {
        updateHistory(&self.history[pos.side][m.from()][m.to()], bonus);
        const idx = contIndex(pos, m);
        if (self.contEntry(ply, 1, idx)) |e| updateHistory16(e, bonus);
        if (self.contEntry(ply, 2, idx)) |e| updateHistory16(e, bonus);
    }

    /// Set the root position. `game_keys` are hashes of earlier positions in
    /// the game (oldest first, excluding the root) for repetition detection.
    pub fn setPosition(self: *Searcher, root: *const Position, game_keys: []const u64) void {
        self.root = root.*;
        const keep = game_keys[game_keys.len - @min(game_keys.len, MAX_KEYS - MAX_PLY - 8) ..];
        @memcpy(self.keys[0..keep.len], keep);
        self.key_len = keep.len;
        self.keys[self.key_len] = root.key;
        self.key_len += 1;
    }

    inline fn elapsedMs(self: *const Searcher) i64 {
        return self.start.durationTo(Io.Clock.awake.now(self.io)).toMilliseconds();
    }

    inline fn isPondering(self: *const Searcher) bool {
        return if (self.pondering) |p| p.load(.monotonic) else false;
    }

    /// Time counted against the limits: everything since the search started,
    /// minus any time spent pondering before ponderhit.
    inline fn limitElapsedMs(self: *const Searcher) i64 {
        return self.elapsedMs() - self.clock_offset_ms.load(.monotonic);
    }

    /// Called from the UCI thread on ponderhit: the clock starts now.
    pub fn ponderhit(self: *Searcher) void {
        self.clock_offset_ms.store(self.elapsedMs(), .monotonic);
        if (self.pondering) |p| p.store(false, .monotonic);
    }

    fn totalNodes(self: *const Searcher) u64 {
        if (self.peers.len == 0) return self.nodes;
        var n: u64 = 0;
        for (self.peers) |p| n += if (p == self) self.nodes else p.shared_nodes.load(.monotonic);
        return n;
    }

    /// Counts a node and polls limits periodically. Returns true if we must stop.
    inline fn tick(self: *Searcher) bool {
        self.nodes += 1;
        if (self.nodes & 1023 == 0) {
            self.shared_nodes.store(self.nodes, .monotonic);
            if (self.stop.load(.monotonic)) self.stopped = true;
            if (self.limits.nodes != 0 and self.nodes >= self.limits.nodes) self.stopped = true;
            if (self.limits.hard_ms != 0 and !self.isPondering() and self.limitElapsedMs() >= self.limits.hard_ms) self.stopped = true;
            if (self.stopped and self.out != null) self.stop.store(true, .monotonic);
        }
        return self.stopped;
    }

    inline fn evaluate(self: *Searcher, pos: *const Position, ply: usize) i32 {
        var e = if (self.net) |n| nnue.evaluate(n, &self.acc[ply], pos) else hce.evaluate(pos);
        // Fade towards a draw as the 50-move counter grows.
        e = @divTrunc(e * (200 - @as(i32, @min(pos.halfmove, 100))), 200);
        return std.math.clamp(e, -MATE_BOUND + 1, MATE_BOUND - 1);
    }

    inline fn makeMove(self: *Searcher, pos: *const Position, m: Move, ply: usize) Position {
        const child = pos.makeMove(m);
        self.tt.prefetch(child.key);
        self.moved[ply] = contIndex(pos, m);
        if (self.net) |n| nnue.update(n, &self.acc[ply], &self.acc[ply + 1], &child);
        self.keys[self.key_len] = child.key;
        self.key_len += 1;
        self.was_null[ply + 1] = false;
        return child;
    }

    inline fn unmake(self: *Searcher) void {
        self.key_len -= 1;
    }

    fn isDraw(self: *const Searcher, pos: *const Position) bool {
        if (pos.halfmove >= 100) return true;
        if (pos.isInsufficientMaterial()) return true;
        const n = self.key_len;
        var i: usize = 4;
        while (i <= pos.halfmove and i < n) : (i += 2) {
            if (self.keys[n - 1 - i] == pos.key) return true;
        }
        return false;
    }

    fn scoreMoves(self: *Searcher, pos: *const Position, sm: *ScoredMoves, tt_move: Move, ply: usize) void {
        const killers = self.killers[ply];
        for (sm.list.slice(), 0..) |m, i| {
            var s: i32 = 0;
            if (m.eql(tt_move)) {
                s = 1 << 30;
            } else if (m.isNoisy()) {
                const victim: usize = if (m.flag() == Move.EP_CAPTURE) 0 else if (m.isCapture()) bb.pieceType(pos.board[m.to()]) else 6;
                const attacker = bb.pieceType(pos.board[m.from()]);
                s = see_value[victim] * 8 - @as(i32, attacker);
                if (m.isPromotion()) {
                    s += if (m.promoType() == bb.QUEEN) 8000 else -3_000_000;
                }
                s += if (see(pos, m, 0)) 2_000_000 else -1_000_000;
            } else if (m.eql(killers[0])) {
                s = 900_000;
            } else if (m.eql(killers[1])) {
                s = 800_000;
            } else {
                s = self.quietHistory(pos, m, ply);
            }
            sm.scores[i] = s;
        }
    }

    inline fn updateHistory(h: *i32, bonus: i32) void {
        h.* += bonus - @divTrunc(h.* * @as(i32, @intCast(@abs(bonus))), 16384);
    }

    inline fn updateHistory16(h: *i16, bonus: i32) void {
        var v: i32 = h.*;
        updateHistory(&v, bonus);
        h.* = @intCast(v);
    }

    pub fn search(self: *Searcher, limits: Limits) Result {
        self.limits = limits;
        self.start = Io.Clock.awake.now(self.io);
        self.nodes = 0;
        self.shared_nodes.store(0, .monotonic);
        self.stopped = false;
        self.clock_offset_ms.store(0, .monotonic);
        self.root_best = Move.none;
        // A search with no legal move returns early: no stale vote.
        self.last = .{ .move = Move.none, .score = 0, .depth = 0 };
        for (&self.killers) |*k| k.* = .{ Move.none, Move.none };
        self.was_null[0] = false;
        for (&self.singular) |*m| m.* = Move.none;
        if (self.net) |n| nnue.refresh(n, &self.acc[0], &self.root);

        var list = MoveList{};
        movegen.generate(&self.root, &list, .all);
        if (list.len == 0) return .{ .move = Move.none, .score = if (self.root.inCheck()) -MATE else 0, .depth = 0 };

        var best = Result{ .move = list.moves[0], .score = 0, .depth = 0 };
        const n_lines = @min(@max(self.multipv, 1), list.len, MAX_MULTIPV);
        var prev = [_]i32{0} ** MAX_MULTIPV;
        var lines: [MAX_MULTIPV]Line = undefined;
        self.n_lines = 0;
        var depth: i32 = 1;
        iterations: while (depth <= limits.depth) : (depth += 1) {
            if (skipDepth(self.thread_index, depth)) continue;
            self.root_depth = depth;
            self.seldepth = 0;
            // Line k is the best move once lines 0..k-1 are excluded at the root.
            for (0..n_lines) |k| {
                for (0..k) |j| self.excluded[j] = lines[j].move;
                self.n_excluded = k;
                self.root_best = Move.none;
                const score = self.aspiration(depth, prev[k]);
                if (self.stopped) {
                    if (k == 0) {
                        if (self.root_best.data != 0) best.move = self.root_best;
                    } else {
                        best.move = lines[0].move;
                        best.score = lines[0].score;
                    }
                    break :iterations;
                }
                const pv = self.pv[0][0..self.pv_len[0]];
                const line = &lines[k];
                line.move = if (self.root_best.data != 0) self.root_best else if (pv.len > 0) pv[0] else list.moves[0];
                line.score = score;
                line.pv_len = legalPrefix(&self.root, pv);
                @memcpy(line.pv[0..line.pv_len], pv[0..line.pv_len]);
                prev[k] = score;
            }
            // Excluded searches shouldn't beat earlier lines, but search noise can.
            std.mem.sort(Line, lines[0..n_lines], {}, struct {
                fn better(_: void, a: Line, b: Line) bool {
                    return a.score > b.score;
                }
            }.better);
            @memcpy(self.lines[0..n_lines], lines[0..n_lines]);
            self.n_lines = n_lines;
            best = .{ .move = lines[0].move, .score = lines[0].score, .depth = depth };
            self.shared_nodes.store(self.nodes, .monotonic);
            if (self.out) |o| self.report(o, depth);
            if (self.isPondering()) continue;
            if (limits.soft_nodes != 0 and self.nodes >= limits.soft_nodes) break;
            if (limits.soft_ms != 0 and self.limitElapsedMs() >= limits.soft_ms) break;
        }
        self.n_excluded = 0;
        self.shared_nodes.store(self.nodes, .monotonic);
        self.last = best;
        return best;
    }

    /// The move to play after a multi-threaded search: each thread's last
    /// result votes for its move, weighted by how far its score is above the
    /// worst thread's and by its depth (Stockfish's vote), so helpers that got
    /// deeper or saw more can overrule the main thread. A mate found by any
    /// thread wins outright (the fastest one).
    pub fn vote(threads: []const *Searcher) Result {
        var min: i32 = std.math.maxInt(i32);
        for (threads) |t| if (t.last.move.data != 0) {
            min = @min(min, t.last.score);
        };
        var best: usize = 0;
        var best_votes: i64 = -1;
        for (threads, 0..) |t, i| {
            if (t.last.move.data == 0) continue;
            if (t.last.score >= MATE_BOUND) {
                if (threads[best].last.score < MATE_BOUND or t.last.score > threads[best].last.score) {
                    best = i;
                    best_votes = std.math.maxInt(i64);
                }
                continue;
            }
            if (best_votes == std.math.maxInt(i64)) continue;
            var votes: i64 = 0;
            for (threads) |u| {
                if (!u.last.move.eql(t.last.move)) continue;
                votes += @as(i64, u.last.score - min + 14) * @max(u.last.depth, 1);
            }
            if (votes > best_votes or (votes == best_votes and t.last.score > threads[best].last.score)) {
                best = i;
                best_votes = votes;
            }
        }
        return threads[best].last;
    }

    inline fn isExcluded(self: *const Searcher, m: Move) bool {
        for (self.excluded[0..self.n_excluded]) |e| if (e.eql(m)) return true;
        return false;
    }

    /// The principal variation, cut at the first move that isn't legal in the
    /// position it would be played from. GUIs replay the PV and reject the
    /// whole info line if any move is illegal.
    pub fn legalPv(self: *const Searcher) []const Move {
        const pv = self.pv[0][0..self.pv_len[0]];
        return pv[0..legalPrefix(&self.root, pv)];
    }

    fn report(self: *Searcher, o: *Output, depth: i32) void {
        const ms: u64 = @intCast(@max(self.elapsedMs(), 0));
        const nodes = self.totalNodes();
        const nps = nodes * 1000 / @max(ms, 1);
        const hashfull = self.tt.hashfull();
        for (self.lines[0..self.n_lines], 1..) |*line, k| {
            var pv_buf: [MAX_PLY * 6]u8 = undefined;
            var w: Io.Writer = .fixed(&pv_buf);
            for (line.pv[0..line.pv_len]) |m| {
                var b: [5]u8 = undefined;
                w.print(" {s}", .{m.toUci(&b)}) catch break;
            }
            var sc_buf: [32]u8 = undefined;
            const score = line.score;
            const sc = if (score >= MATE_BOUND)
                std.fmt.bufPrint(&sc_buf, "mate {d}", .{@divTrunc(MATE - score + 1, 2)}) catch ""
            else if (score <= -MATE_BOUND)
                std.fmt.bufPrint(&sc_buf, "mate -{d}", .{@divTrunc(MATE + score, 2)}) catch ""
            else
                std.fmt.bufPrint(&sc_buf, "cp {d}", .{score}) catch "";
            o.print("info depth {d} seldepth {d} multipv {d} score {s} nodes {d} nps {d} hashfull {d} time {d} pv{s}\n", .{
                depth, self.seldepth, k, sc, nodes, nps, hashfull, ms, w.buffered(),
            });
        }
    }

    fn aspiration(self: *Searcher, depth: i32, prev: i32) i32 {
        if (depth < 4) return self.negamax(&self.root, -INF, INF, depth, 0, true, false);
        var delta: i32 = 20;
        var alpha = @max(prev - delta, -INF);
        var beta = @min(prev + delta, INF);
        while (true) {
            const s = self.negamax(&self.root, alpha, beta, depth, 0, true, false);
            if (self.stopped) return s;
            if (s <= alpha) {
                beta = @divTrunc(alpha + beta, 2);
                alpha = @max(s - delta, -INF);
            } else if (s >= beta) {
                beta = @min(s + delta, INF);
            } else return s;
            delta += @divTrunc(delta, 2);
        }
    }

    fn negamax(self: *Searcher, pos: *const Position, alpha_in: i32, beta_in: i32, depth_in: i32, ply: usize, comptime pv_node: bool, cut_node: bool) i32 {
        var alpha = alpha_in;
        var beta = beta_in;
        var depth = depth_in;
        const root = ply == 0;
        if (pv_node) self.pv_len[ply] = ply;
        if (depth <= 0) return self.qsearch(pos, alpha, beta, ply, pv_node);
        if (self.tick()) return 0;
        if (ply > self.seldepth) self.seldepth = ply;
        const in_check = pos.inCheck();
        const pi: i32 = @intCast(ply);

        if (!root) {
            if (self.isDraw(pos)) return 0;
            if (ply >= MAX_PLY - 1) return if (in_check) 0 else self.evaluate(pos, ply);
            alpha = @max(alpha, -MATE + pi);
            beta = @min(beta, MATE - pi - 1);
            if (alpha >= beta) return alpha;
        }

        // In a singular verification search the TT entry is this node's own:
        // its move is excluded and its score can't be trusted for cutoffs.
        const excluded = self.singular[ply];
        const verifying = excluded.data != 0;
        var tt_move = Move.none;
        var tt_score: i32 = 0;
        var tt_bound: tt_mod.Bound = .none;
        var tt_depth: i32 = 0;
        var tt_eval: i32 = EVAL_NONE;
        if (self.tt.probe(pos.key)) |e| {
            tt_move = .{ .data = e.move };
            tt_score = scoreFromTT(e.score, ply);
            tt_bound = e.bound;
            tt_depth = e.depth;
            tt_eval = e.eval;
            if (!pv_node and !verifying and e.depth >= depth) {
                if (tt_bound == .exact or (tt_bound == .lower and tt_score >= beta) or (tt_bound == .upper and tt_score <= alpha))
                    return tt_score;
            }
        }

        var static_eval: i32 = EVAL_NONE;
        var eval: i32 = EVAL_NONE;
        if (!in_check) {
            static_eval = if (tt_eval != EVAL_NONE) tt_eval else self.evaluate(pos, ply);
            eval = static_eval;
            if (tt_bound == .exact or (tt_bound == .lower and tt_score > eval) or (tt_bound == .upper and tt_score < eval))
                eval = tt_score;
        }
        self.evals[ply] = static_eval;
        const improving = !in_check and ply >= 2 and self.evals[ply - 2] != EVAL_NONE and static_eval > self.evals[ply - 2];
        const imp: i32 = @intFromBool(improving);
        self.killers[ply + 1] = .{ Move.none, Move.none };

        if (!pv_node and !in_check and !verifying) {
            // Reverse futility pruning.
            if (depth <= 8 and eval < MATE_BOUND and eval - 80 * (depth - imp) >= beta)
                return @divTrunc(eval + beta, 2);

            // Null-move pruning.
            if (depth >= 3 and eval >= beta and static_eval >= beta and !self.was_null[ply] and
                beta > -MATE_BOUND and pos.hasNonPawnMaterial(pos.side))
            {
                const r = 3 + @divTrunc(depth, 3) + @min(@divTrunc(eval - beta, 200), 3);
                const child = pos.makeNull();
                if (self.net != null) self.acc[ply + 1] = self.acc[ply];
                self.keys[self.key_len] = child.key;
                self.key_len += 1;
                self.was_null[ply + 1] = true;
                self.moved[ply] = NO_CONT;
                const s = -self.negamax(&child, -beta, -beta + 1, depth - r, ply + 1, false, !cut_node);
                self.unmake();
                if (self.stopped) return 0;
                if (s >= beta) return if (s >= MATE_BOUND) beta else s;
            }
        }

        // Internal iterative reduction: no TT move means poor ordering here.
        if (depth >= 4 and tt_move.data == 0 and (pv_node or cut_node)) depth -= 1;

        var sm = ScoredMoves{};
        movegen.generate(pos, &sm.list, .all);
        if (sm.list.len == 0) return if (in_check) -MATE + pi else 0;
        self.scoreMoves(pos, &sm, tt_move, ply);

        var best_score: i32 = -INF;
        var best_move = Move.none;
        var quiets: [64]Move = undefined;
        var n_quiets: usize = 0;
        var searched: usize = 0;
        const has_material = pos.hasNonPawnMaterial(pos.side);

        for (0..sm.list.len) |i| {
            const m = sm.pick(i);
            if (root and self.n_excluded > 0 and self.isExcluded(m)) continue;
            if (verifying and m.eql(excluded)) continue;
            const quiet = !m.isNoisy();

            if (!root and best_score > -MATE_BOUND and has_material) {
                if (quiet) {
                    // Late move pruning.
                    const lmp_limit: usize = @intCast(@divTrunc(3 + depth * depth, 2 - imp));
                    if (!pv_node and depth <= 8 and searched >= lmp_limit) continue;
                    // Futility pruning.
                    if (!in_check and depth <= 8 and static_eval + 100 + 100 * depth <= alpha) continue;
                    // SEE pruning of quiets that hang material.
                    if (depth <= 8 and !see(pos, m, -70 * depth)) continue;
                } else {
                    if (depth <= 8 and !see(pos, m, -100 * depth)) continue;
                }
            }

            // Singular extension: if every other move fails well below the TT
            // score, the TT move is the only good one and gets searched deeper.
            var ext: i32 = 0;
            if (!root and !verifying and depth >= 8 and m.eql(tt_move) and tt_bound != .upper and
                tt_depth >= depth - 3 and @abs(tt_score) < MATE_BOUND and pi < 2 * self.root_depth)
            {
                const s_beta = tt_score - 2 * depth;
                self.singular[ply] = m;
                const s = self.negamax(pos, s_beta - 1, s_beta, @divTrunc(depth - 1, 2), ply, false, cut_node);
                self.singular[ply] = Move.none;
                if (self.stopped) return 0;
                if (s < s_beta) {
                    ext = if (!pv_node and s < s_beta - 20) 2 else 1;
                } else if (s_beta >= beta) {
                    // Multi-cut: another move also beats beta.
                    return s_beta;
                } else if (tt_score >= beta) {
                    ext = -1;
                }
            }

            const child = self.makeMove(pos, m, ply);
            const gives_check = child.inCheck();
            if (ext == 0 and gives_check and pi < 2 * self.root_depth) ext = 1;
            const new_depth = depth - 1 + ext;
            var score: i32 = undefined;

            if (searched == 0) {
                score = -self.negamax(&child, -beta, -alpha, new_depth, ply + 1, pv_node, false);
            } else {
                var r: i32 = 0;
                if (depth >= 3 and searched >= 1 + @as(usize, @intFromBool(pv_node)) and quiet) {
                    r = lmr_table[@intCast(@min(depth, 63))][@min(searched, 63)];
                    r += @intFromBool(!pv_node);
                    r += @intFromBool(cut_node);
                    r -= imp;
                    r -= @intFromBool(gives_check);
                    r -= @divTrunc(self.quietHistory(pos, m, ply), 16384);
                    r = std.math.clamp(r, 0, new_depth - 1);
                }
                score = -self.negamax(&child, -alpha - 1, -alpha, new_depth - r, ply + 1, false, true);
                if (score > alpha and r > 0)
                    score = -self.negamax(&child, -alpha - 1, -alpha, new_depth, ply + 1, false, !cut_node);
                if (pv_node and score > alpha and score < beta)
                    score = -self.negamax(&child, -beta, -alpha, new_depth, ply + 1, true, false);
            }
            self.unmake();
            if (self.stopped) return 0;
            searched += 1;

            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    best_move = m;
                    alpha = score;
                    if (root) self.root_best = m;
                    if (pv_node) {
                        self.pv[ply][ply] = m;
                        const child_len = self.pv_len[ply + 1];
                        for (ply + 1..child_len) |k| self.pv[ply][k] = self.pv[ply + 1][k];
                        self.pv_len[ply] = @max(child_len, ply + 1);
                    }
                    if (score >= beta) {
                        if (quiet) {
                            const k = &self.killers[ply];
                            if (!k[0].eql(m)) {
                                k[1] = k[0];
                                k[0] = m;
                            }
                            const bonus = @min(16 * depth * depth + 32 * depth, 1500);
                            self.updateQuietHistory(pos, m, ply, bonus);
                            for (quiets[0..n_quiets]) |q| self.updateQuietHistory(pos, q, ply, -bonus);
                        }
                        break;
                    }
                }
            }
            if (quiet and n_quiets < quiets.len) {
                quiets[n_quiets] = m;
                n_quiets += 1;
            }
        }

        const bound: tt_mod.Bound = if (best_score >= beta) .lower else if (best_move.data != 0) .exact else .upper;
        // With root moves excluded (MultiPV) or a move skipped for a singular
        // verification this isn't the node's true value.
        if (!(root and self.n_excluded > 0) and !verifying)
            self.tt.store(pos.key, best_move, scoreToTT(best_score, ply), if (in_check) EVAL_NONE else static_eval, depth, bound);
        return best_score;
    }

    fn qsearch(self: *Searcher, pos: *const Position, alpha_in: i32, beta: i32, ply: usize, comptime pv_node: bool) i32 {
        var alpha = alpha_in;
        if (self.tick()) return 0;
        if (pv_node and ply > self.seldepth) self.seldepth = ply;
        if (pos.halfmove >= 100 or pos.isInsufficientMaterial()) return 0;
        const in_check = pos.inCheck();
        if (ply >= MAX_PLY - 1) return if (in_check) 0 else self.evaluate(pos, ply);

        var tt_move = Move.none;
        var tt_eval: i32 = EVAL_NONE;
        if (self.tt.probe(pos.key)) |e| {
            tt_move = .{ .data = e.move };
            tt_eval = e.eval;
            const s = scoreFromTT(e.score, ply);
            if (!pv_node and (e.bound == .exact or (e.bound == .lower and s >= beta) or (e.bound == .upper and s <= alpha)))
                return s;
        }

        var best: i32 = -INF;
        var stand_pat: i32 = EVAL_NONE;
        if (!in_check) {
            stand_pat = if (tt_eval != EVAL_NONE) tt_eval else self.evaluate(pos, ply);
            if (stand_pat >= beta) return stand_pat;
            if (stand_pat > alpha) alpha = stand_pat;
            best = stand_pat;
        }

        var sm = ScoredMoves{};
        if (in_check) movegen.generate(pos, &sm.list, .all) else movegen.generate(pos, &sm.list, .noisy);
        if (in_check and sm.list.len == 0) return -MATE + @as(i32, @intCast(ply));
        self.scoreMoves(pos, &sm, tt_move, ply);

        var best_move = Move.none;
        for (0..sm.list.len) |i| {
            const m = sm.pick(i);
            if (!in_check) {
                if (!see(pos, m, 0)) continue;
                // Delta pruning: even winning this piece cannot reach alpha.
                if (!m.isPromotion() and m.isCapture()) {
                    const victim: usize = if (m.flag() == Move.EP_CAPTURE) 0 else bb.pieceType(pos.board[m.to()]);
                    if (stand_pat + see_value[victim] + 200 <= alpha) continue;
                }
            }
            const child = self.makeMove(pos, m, ply);
            const score = -self.qsearch(&child, -beta, -alpha, ply + 1, pv_node);
            self.unmake();
            if (self.stopped) return 0;
            if (score > best) {
                best = score;
                if (score > alpha) {
                    alpha = score;
                    best_move = m;
                    if (score >= beta) break;
                }
            }
        }

        const bound: tt_mod.Bound = if (best >= beta) .lower else if (best_move.data != 0) .exact else .upper;
        self.tt.store(pos.key, best_move, scoreToTT(best, ply), if (in_check) EVAL_NONE else stand_pat, 0, bound);
        return best;
    }
};

test "see basics" {
    atk.init();
    // Pawn takes undefended knight: wins material.
    const p1 = try Position.fromFen("4k3/8/8/3n4/4P3/8/8/4K3 w - - 0 1");
    try std.testing.expect(see(&p1, Move.init(28, 35, Move.CAPTURE), 0));
    // Queen takes pawn defended by pawn: loses material.
    const p2 = try Position.fromFen("4k3/8/2p5/3p4/8/8/3Q4/4K3 w - - 0 1");
    try std.testing.expect(!see(&p2, Move.init(11, 35, Move.CAPTURE), 0));
}

test "principal variations are legal" {
    atk.init();
    const gpa = std.testing.allocator;
    var tt = try TT.init(gpa, 16);
    defer tt.deinit(gpa);
    var stop = std.atomic.Value(bool).init(false);
    const s = try Searcher.create(gpa, std.testing.io, &tt, null, &stop);
    defer gpa.destroy(s);
    const fens = [_][]const u8{
        position.START_FEN,
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1", // mate in 1
        "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", // Qxf7#
        "8/8/8/8/8/5k2/8/4K2R w K - 0 1", // KR vs K
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "2kr3r/ppp2ppp/2n5/2b1q3/4P3/2P2N2/PP1Q1PPP/RNB1KB1R b KQ - 0 10",
        "6k1/5p2/6p1/8/7p/8/6PP/6K1 b - - 0 1",
    };
    var illegal: usize = 0;
    for (fens) |fen| {
        const pos = try Position.fromFen(fen);
        tt.clear();
        s.clearHistory();
        s.setPosition(&pos, &.{});
        for (1..13) |d| {
            _ = s.search(.{ .depth = @intCast(d) });
            if (s.legalPv().len != s.pv_len[0]) illegal += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), illegal);
}

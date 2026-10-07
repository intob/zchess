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

const Class = enum { good, inaccuracy, mistake, blunder };
const Kind = enum { other, hung_piece, missed_capture, missed_mate, allowed_mate, bad_capture };

const piece_names = [6][]const u8{ "pawn", "knight", "bishop", "rook", "queen", "king" };
const see_value = [6]i32{ 100, 300, 300, 500, 900, 0 };

/// Winning chances (0..100) for the side with score `cp` (Lichess formula).
fn winPct(cp: i32) f64 {
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
const Eval = struct {
    score: i32, // side to move's point of view
    best: Move,
    pv: [8]Move,
    pv_len: usize,
};

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
    result: u8 = 1, // 0 loss, 1 draw, 2 win (user's point of view)
    accuracy: f64 = 0,
    counts: [4]u32 = .{ 0, 0, 0, 0 },
    kinds: [6]u32 = .{0} ** 6,
};

fn userIsWhite(in: *const Input, user: []const u8) bool {
    return std.ascii.eqlIgnoreCase(in.header("White"), user);
}

fn phaseOf(pos: *const Position, ply: usize) []const u8 {
    if (ply < 20) return "opening";
    const npm = bb.popcount(pos.pieces[bb.KNIGHT] | pos.pieces[bb.BISHOP]) +
        2 * bb.popcount(pos.pieces[bb.ROOK]) + 4 * bb.popcount(pos.pieces[bb.QUEEN]);
    return if (npm <= 8) "endgame" else "middlegame";
}

fn victimOf(pos: *const Position, m: Move) ?bb.PieceType {
    if (m.flag() == Move.EP_CAPTURE) return bb.PAWN;
    if (!m.isCapture()) return null;
    return bb.pieceType(pos.board[m.to()]);
}

const Label = struct {
    kind: Kind = .other,
    piece: ?bb.PieceType = null,
    /// A second lesson in the same move: "and left your knight hanging".
    also_hung: ?bb.PieceType = null,
};

/// Plain-language label for a flagged move. When the move both missed a win of
/// material and left something hanging, the bigger swing leads and the other
/// is mentioned too.
/// A capture counts as winning material when it nets at least this much
/// (centipawns, by static exchange), even if the capturing piece is lost back.
const min_gain = 200;

fn classifyKind(positions: []const Position, evals: []const Eval, moves: []const Move, i: usize) Label {
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
    if (hung) |h| return .{ .kind = .hung_piece, .piece = h };
    if (moves[i].isCapture() and !search.see(&positions[i], moves[i], 0)) return .{ .kind = .bad_capture, .piece = victimOf(&positions[i], moves[i]) };
    return .{};
}

fn explain(l: Label, best_san: []const u8, buf: []u8) []const u8 {
    const p = if (l.piece) |pt| piece_names[pt] else "piece";
    return switch (l.kind) {
        .allowed_mate => "allowed a forced checkmate",
        .missed_mate => std.fmt.bufPrint(buf, "missed a forced checkmate starting with {s}", .{best_san}) catch "missed a forced checkmate",
        .hung_piece => std.fmt.bufPrint(buf, "left your {s} hanging", .{p}) catch "left a piece hanging",
        .missed_capture => if (l.also_hung) |h|
            std.fmt.bufPrint(buf, "missed taking the {s} with {s}, and left your {s} hanging", .{ p, best_san, piece_names[h] }) catch "missed winning material"
        else
            std.fmt.bufPrint(buf, "missed taking the {s} with {s}", .{ p, best_san }) catch "missed winning material",
        .bad_capture => "captured into a losing exchange",
        .other => "weakened your position",
    };
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

fn pgnEval(score: i32, side: bb.Color, buf: []u8) []const u8 {
    const white = if (side == bb.WHITE) score else -score;
    if (@abs(white) >= search.MATE_BOUND) {
        const moves = @divTrunc(search.MATE - @as(i32, @intCast(@abs(white))) + 1, 2);
        return std.fmt.bufPrint(buf, "#{s}{d}", .{ if (white < 0) "-" else "", moves }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>2}", .{ if (white < 0) "-" else "", @abs(white) / 100, @abs(white) % 100 }) catch "";
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
        var list = movegen.MoveList{};
        movegen.generate(p, &list, .all);
        if (list.len == 0) {
            evals[i] = .{ .score = if (p.inCheck()) -search.MATE else 0, .best = Move.none, .pv = undefined, .pv_len = 0 };
        } else {
            s.setPosition(p, keys.items);
            const r = s.search(.{ .soft_nodes = ctx.nodes, .nodes = ctx.nodes * 3 });
            var e = Eval{ .score = r.score, .best = r.move, .pv = undefined, .pv_len = @min(s.pv_len[0], 8) };
            for (0..e.pv_len) |k| e.pv[k] = s.pv[0][k];
            if (e.pv_len == 0 or !e.pv[0].eql(r.move)) {
                e.pv[0] = r.move;
                e.pv_len = 1;
            }
            evals[i] = e;
        }
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
        const drop = @max(0, winPct(evals[i].score) - winPct(-evals[i + 1].score));
        acc_sum += moveAccuracy(drop);
        user_moves += 1;
        const cls: Class = if (drop >= 30) .blunder else if (drop >= 20) .mistake else if (drop >= 10) .inaccuracy else .good;
        if (cls == .good) continue;
        const label = classifyKind(positions.items, evals, moves.items, i);
        try flags.append(gpa, .{ .ply = i, .cls = cls, .label = label, .drop = drop });
        sum.counts[@intFromEnum(cls)] += 1;
        if (cls != .inaccuracy) sum.kinds[@intFromEnum(label.kind)] += 1;
    }
    sum.accuracy = if (user_moves > 0) acc_sum / @as(f64, @floatFromInt(user_moves)) else 0;
    const res = in.header("Result");
    sum.result = if (std.mem.eql(u8, res, "1/2-1/2")) 1 else if (std.mem.eql(u8, res, if (user_white) "1-0" else "0-1")) 2 else if (std.mem.eql(u8, res, "*")) 1 else 0;

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
        if (user_white) "white" else "black", ([_][]const u8{ "loss", "draw", "win" })[sum.result], sum.accuracy, sum.counts[1], sum.counts[2], sum.counts[3],
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
        var eb: [128]u8 = undefined;
        var bsb: [16]u8 = undefined;
        if (fi > 0) try w.writeByte(',');
        try w.print("{{\"ply\":{d},\"move_no\":{d},\"san\":", .{ f.ply, p.fullmove });
        try writeJsonString(w, play.san(p, moves.items[f.ply], &sb));
        try w.print(",\"cls\":\"{s}\",\"kind\":\"{s}\",\"piece\":\"{s}\",\"best\":", .{ @tagName(f.cls), @tagName(f.label.kind), if (f.label.piece) |pt| piece_names[pt] else "" });
        try writeJsonString(w, play.san(p, evals[f.ply].best, &bsb));
        try w.writeAll(",\"explain\":");
        try writeJsonString(w, explain(f.label, play.san(p, evals[f.ply].best, &bsb), &eb));
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
    try w.writeAll("]}");
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
        var xb: [128]u8 = undefined;
        try o.print(" Biggest moment: {d}{s} {s}, which {s}.", .{
            p.fullmove, if (p.side == bb.WHITE) "." else "...", play.san(p, moves.items[f.ply], &sb), explain(f.label, play.san(p, evals[f.ply].best, &bsb), &xb),
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
            var xb: [128]u8 = undefined;
            var bsb: [16]u8 = undefined;
            var bsb2: [16]u8 = undefined;
            const cls_name = ([_][]const u8{ "", "Inaccuracy", "Mistake", "Blunder" })[@intFromEnum(f.cls)];
            try o.print(" {{[%eval {s}] {s}: {s}. Best was {s}.}}", .{
                pgnEval(evals[i + 1].score, positions.items[i + 1].side, &eb), cls_name, explain(f.label, play.san(p, evals[i].best, &bsb2), &xb), play.san(p, evals[i].best, &bsb),
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
        done, ctx.inputs.len, in.header("Date"), opp, ([_][]const u8{ "loss", "draw", "win" })[sum.result], sum.accuracy, sum.counts[3], sum.counts[2], sum.counts[1],
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
    var wdl = [3]u32{ 0, 0, 0 };
    var acc: f64 = 0;
    for (ctx.summaries) |sm| {
        if (!sm.analysed) continue;
        analysed += 1;
        wdl[sm.result] += 1;
        acc += sm.accuracy;
        for (0..4) |k| total.counts[k] += sm.counts[k];
        for (0..6) |k| total.kinds[k] += sm.kinds[k];
    }

    {
        const f = try Io.Dir.cwd().createFile(io, json_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var fw = f.writer(io, &buf);
        const w = &fw.interface;
        try w.writeAll("{\"user\":");
        try writeJsonString(w, user);
        try w.print(",\"nodes\":{d},\"games_analysed\":{d},\"wins\":{d},\"draws\":{d},\"losses\":{d},\"avg_accuracy\":{d:.1},", .{
            nodes, analysed, wdl[2], wdl[1], wdl[0], if (analysed > 0) acc / @as(f64, @floatFromInt(analysed)) else 0,
        });
        try w.print("\"totals\":{{\"inaccuracy\":{d},\"mistake\":{d},\"blunder\":{d}}},\"kinds\":{{", .{ total.counts[1], total.counts[2], total.counts[3] });
        for (std.enums.values(Kind), 0..) |k, ki| {
            if (ki > 0) try w.writeByte(',');
            try w.print("\"{s}\":{d}", .{ @tagName(k), total.kinds[@intFromEnum(k)] });
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

    out.print("\n{d} games: +{d} ={d} -{d}, average accuracy {d:.0}%\n", .{ analysed, wdl[2], wdl[1], wdl[0], if (analysed > 0) acc / @as(f64, @floatFromInt(analysed)) else 0 });
    out.print("{d} blunders, {d} mistakes, {d} inaccuracies\n", .{ total.counts[3], total.counts[2], total.counts[1] });
    out.print("mistakes and blunders by type: hung a piece {d}, missed a capture {d}, allowed mate {d}, missed mate {d}, bad capture {d}, other {d}\n", .{
        total.kinds[@intFromEnum(Kind.hung_piece)], total.kinds[@intFromEnum(Kind.missed_capture)], total.kinds[@intFromEnum(Kind.allowed_mate)],
        total.kinds[@intFromEnum(Kind.missed_mate)], total.kinds[@intFromEnum(Kind.bad_capture)], total.kinds[@intFromEnum(Kind.other)],
    });
    out.print("-> {s}, {s}\n", .{ json_path, pgn_path });
}

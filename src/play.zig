//! Play against the engine in the terminal.

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
const strength = @import("strength.zig");
const coach = @import("coach.zig");
const openings = @import("openings.zig");

const Position = position.Position;
const Move = position.Move;

const help =
    \\usage: zchess play [--black] [--time <seconds>] [--elo <100-3000>] [--net <file|hce>] [--fen <fen>]
    \\                   [--coach [--games <pgn file or dir> [--user <name>]] [--threats] [--hints]]
    \\
    \\Enter moves as SAN (e4, Nf3, exd5, O-O, e8=Q) or coordinates (e2e4).
    \\Commands: moves, undo, flip, hint, help, quit
    \\--coach: a comment on each of your moves, judged as `zchess review` would, with
    \\opening names and theory; --games adds your record from your own games (and the
    \\focus from the folder's .focus file, see scripts/ec-sync.py); --threats also says
    \\what each engine move threatens; --hints points out your loose pieces after it.
    \\
;

/// Standard algebraic notation for a legal move.
pub fn san(pos: *const Position, m: Move, buf: *[16]u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    if (m.isCastle()) {
        w.writeAll(if (m.flag() == Move.KING_CASTLE) "O-O" else "O-O-O") catch {};
    } else {
        const pt = bb.pieceType(pos.board[m.from()]);
        const from = bb.squareName(m.from());
        if (pt == bb.PAWN) {
            if (m.isCapture()) w.writeByte(from[0]) catch {};
        } else {
            w.writeByte("PNBRQK"[pt]) catch {};
            // Disambiguate against other pieces of the same type reaching the same square.
            var list = movegen.MoveList{};
            movegen.generate(pos, &list, .all);
            var clash = false;
            var same_file = false;
            var same_rank = false;
            for (list.slice()) |o| {
                if (o.eql(m) or o.to() != m.to() or o.from() == m.from()) continue;
                if (bb.pieceType(pos.board[o.from()]) != pt) continue;
                clash = true;
                if (bb.fileOf(o.from()) == bb.fileOf(m.from())) same_file = true;
                if (bb.rankOf(o.from()) == bb.rankOf(m.from())) same_rank = true;
            }
            if (clash) {
                if (!same_file) {
                    w.writeByte(from[0]) catch {};
                } else if (!same_rank) {
                    w.writeByte(from[1]) catch {};
                } else w.writeAll(&from) catch {};
            }
        }
        if (m.isCapture()) w.writeByte('x') catch {};
        w.writeAll(&bb.squareName(m.to())) catch {};
        if (m.isPromotion()) w.print("={c}", .{"PNBRQK"[m.promoType()]}) catch {};
    }
    const child = pos.makeMove(m);
    if (child.inCheck()) {
        var replies = movegen.MoveList{};
        movegen.generate(&child, &replies, .all);
        w.writeByte(if (replies.len == 0) '#' else '+') catch {};
    }
    return w.buffered();
}

fn normalize(s: []const u8, buf: *[16]u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n == buf.len) break;
        switch (c) {
            '+', '#', '!', '?', 'x', '=', ':', '-', ' ' => {},
            '0' => {
                buf[n] = 'O';
                n += 1;
            },
            else => {
                buf[n] = c;
                n += 1;
            },
        }
    }
    return buf[0..n];
}

pub fn parseMove(pos: *const Position, input: []const u8) ?Move {
    if (movegen.parseUci(pos, input)) |m| return m;
    var nb: [16]u8 = undefined;
    const want = normalize(input, &nb);
    var list = movegen.MoveList{};
    movegen.generate(pos, &list, .all);
    for (list.slice()) |m| {
        var sb: [16]u8 = undefined;
        var mb: [16]u8 = undefined;
        if (std.mem.eql(u8, normalize(san(pos, m, &sb), &mb), want)) return m;
    }
    return null;
}

const glyphs = [12][]const u8{ "♙", "♘", "♗", "♖", "♕", "♔", "♟", "♞", "♝", "♜", "♛", "♚" };

fn printBoard(out: *Output, pos: *const Position, white_bottom: bool, last: Move) void {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    w.writeByte('\n') catch {};
    for (0..8) |ri| {
        const rank: u6 = @intCast(if (white_bottom) 7 - ri else ri);
        w.print(" {d} ", .{@as(u8, rank) + 1}) catch {};
        for (0..8) |fi| {
            const file: u6 = @intCast(if (white_bottom) fi else 7 - fi);
            const sq: bb.Square = rank * 8 + file;
            const light = (rank + file) % 2 == 1;
            const hl = last.data != 0 and (sq == last.from() or sq == last.to());
            // Background: highlighted last move, otherwise light/dark squares.
            const bg = if (hl) "\x1b[48;5;143m" else if (light) "\x1b[48;5;180m" else "\x1b[48;5;137m";
            const pc = pos.board[sq];
            if (pc == bb.NO_PIECE) {
                w.print("{s}   ", .{bg}) catch {};
            } else {
                // Draw both colours with the filled glyph; colour tells them apart.
                const fg = if (bb.pieceColor(pc) == bb.WHITE) "\x1b[97m" else "\x1b[30m";
                w.print("{s}{s} {s} ", .{ bg, fg, glyphs[6 + @as(usize, bb.pieceType(pc))] }) catch {};
            }
        }
        w.writeAll("\x1b[0m\n") catch {};
    }
    w.writeAll(if (white_bottom) "    a  b  c  d  e  f  g  h\n" else "    h  g  f  e  d  c  b  a\n") catch {};
    out.print("{s}", .{w.buffered()});
}

fn formatScore(score: i32, side: bb.Color, buf: []u8) []const u8 {
    const white = if (side == bb.WHITE) score else -score;
    if (@abs(white) >= search.MATE_BOUND) {
        const plies = search.MATE - @as(i32, @intCast(@abs(white)));
        const moves = @divTrunc(plies + 1, 2);
        return std.fmt.bufPrint(buf, "{s}mate in {d}", .{ if (white > 0) "White " else "Black ", moves }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>2}", .{ if (white >= 0) "+" else "-", @abs(white) / 100, @abs(white) % 100 }) catch "";
}

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Output, args: []const [:0]const u8) !void {
    var p = cli.Parser{ .args = args };
    var human: bb.Color = bb.WHITE;
    var think_ms: i64 = 3000;
    var elo: ?u32 = null;
    var net_path: []const u8 = "";
    var fen: []const u8 = position.START_FEN;
    var coaching = false;
    var threats = false;
    var hints = false;
    var games_path: []const u8 = "";
    var user: []const u8 = "";
    while (p.next()) |a| {
        if (std.mem.eql(u8, a, "--black")) human = bb.BLACK
        else if (std.mem.eql(u8, a, "--white")) human = bb.WHITE
        else if (p.float(a, "--time")) |v| think_ms = @intFromFloat(@max(v, 0.05) * 1000)
        else if (p.int(u32, a, "--elo")) |v| elo = std.math.clamp(v, strength.MIN_ELO, strength.MAX_ELO)
        else if (p.flag(a, "--net")) |v| net_path = v
        else if (p.flag(a, "--fen")) |v| fen = v
        else if (std.mem.eql(u8, a, "--coach")) coaching = true
        else if (std.mem.eql(u8, a, "--threats")) threats = true
        else if (std.mem.eql(u8, a, "--hints")) hints = true
        else if (p.flag(a, "--games")) |v| games_path = v
        else if (p.flag(a, "--user")) |v| user = v
        else {
            out.print("{s}", .{help});
            return;
        }
    }

    const net = try cli.loadNet(gpa, io, net_path);
    var tt = try TT.init(gpa, 256);
    defer tt.deinit(gpa);
    var stop = std.atomic.Value(bool).init(false);
    const engine = try search.Searcher.create(gpa, io, &tt, net, &stop);
    var prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(Io.Clock.real.now(io).toNanoseconds()))));
    defer gpa.destroy(engine);

    var history: std.ArrayList(Position) = .empty;
    defer history.deinit(gpa);
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(gpa);
    var moves: std.ArrayList(Move) = .empty;
    defer moves.deinit(gpa);

    var pos = Position.fromFen(fen) catch {
        out.print("invalid fen\n", .{});
        return;
    };
    var coach_ctx = coach.Context{ .book = openings.Book.embeddedBook(), .hints = hints };
    var rep: ?openings.Repertoire = null;
    defer if (rep) |*r| r.deinit();
    if (coaching and games_path.len > 0) {
        rep = openings.Repertoire.load(gpa, io, games_path, user) catch |err| blk: {
            out.print("can't read games from {s}: {s}\n", .{ games_path, @errorName(err) });
            break :blk null;
        };
        if (rep) |*r| {
            coach_ctx.rep = r;
            out.print("coach: {d} of your games as {s}\n", .{ r.games, r.user() });
        }
        coach_ctx.focus = coach.Focus.load(io, games_path);
    }
    var white_bottom = human == bb.WHITE;
    var last = Move.none;

    var in_buf: [1024]u8 = undefined;
    var fr = Io.File.stdin().reader(io, &in_buf);

    out.print("zchess ({s}), {d:.1}s per move. You play {s}. Type 'help' for commands.\n", .{
        if (net != null) "NNUE" else "hand-crafted eval", @as(f64, @floatFromInt(think_ms)) / 1000, if (human == bb.WHITE) "White" else "Black",
    });

    while (true) {
        printBoard(out, &pos, white_bottom, last);
        if (game.terminal(&pos, keys.items)) |o| {
            const msg = switch (o) {
                .draw => "Draw.",
                .white => if (human == bb.WHITE) "Checkmate - you win!" else "Checkmate - White wins.",
                .black => if (human == bb.BLACK) "Checkmate - you win!" else "Checkmate - Black wins.",
            };
            out.print("\n{s}\n", .{msg});
            return;
        }

        const move: Move = if (pos.side == human) blk: {
            while (true) {
                out.print("\nyour move> ", .{});
                const raw = (fr.interface.takeDelimiter('\n') catch null) orelse return;
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) return;
                if (std.mem.eql(u8, line, "help")) {
                    out.print("{s}", .{help});
                    continue;
                }
                if (std.mem.eql(u8, line, "flip")) {
                    white_bottom = !white_bottom;
                    printBoard(out, &pos, white_bottom, last);
                    continue;
                }
                if (std.mem.eql(u8, line, "moves")) {
                    var list = movegen.MoveList{};
                    movegen.generate(&pos, &list, .all);
                    for (list.slice()) |m| {
                        var sb: [16]u8 = undefined;
                        out.print("{s} ", .{san(&pos, m, &sb)});
                    }
                    out.print("\n", .{});
                    continue;
                }
                if (std.mem.eql(u8, line, "undo")) {
                    // Take back your last move and the engine's reply.
                    if (history.items.len >= 2) {
                        for (0..2) |_| {
                            pos = history.pop().?;
                            _ = keys.pop();
                            _ = moves.pop();
                        }
                        last = if (moves.items.len > 0) moves.items[moves.items.len - 1] else Move.none;
                        printBoard(out, &pos, white_bottom, last);
                    } else out.print("nothing to undo\n", .{});
                    continue;
                }
                if (std.mem.eql(u8, line, "hint")) {
                    engine.setPosition(&pos, keys.items);
                    const r = engine.search(.{ .soft_ms = @divTrunc(think_ms, 2), .hard_ms = think_ms });
                    var sb: [16]u8 = undefined;
                    var scb: [32]u8 = undefined;
                    out.print("hint: {s} ({s})\n", .{ san(&pos, r.move, &sb), formatScore(r.score, pos.side, &scb) });
                    continue;
                }
                if (parseMove(&pos, line)) |m| break :blk m;
                out.print("illegal or unrecognised move '{s}' (type 'moves' to list legal moves)\n", .{line});
            }
        } else blk: {
            out.print("\nthinking...\n", .{});
            engine.setPosition(&pos, keys.items);
            const r = if (elo) |level|
                strength.choose(engine, prng.random(), level, .{ .soft_ms = @divTrunc(think_ms * 6, 10), .hard_ms = think_ms }).result
            else
                engine.search(.{ .soft_ms = @divTrunc(think_ms * 6, 10), .hard_ms = think_ms });
            var sb: [16]u8 = undefined;
            var scb: [32]u8 = undefined;
            const move_no = pos.fullmove;
            out.print("{d}.{s} {s}   eval {s}  depth {d}\n", .{
                move_no, if (pos.side == bb.WHITE) "" else "..", san(&pos, r.move, &sb), formatScore(r.score, pos.side, &scb), r.depth,
            });
            break :blk r.move;
        };

        try history.append(gpa, pos);
        try keys.append(gpa, pos.key);
        try moves.append(gpa, move);
        if (coaching and pos.side == human) {
            var cb: [3072]u8 = undefined;
            var w: Io.Writer = .fixed(&cb);
            coach.comment(engine, &coach_ctx, &pos, move, keys.items, &w) catch {};
            out.print("coach: {s}\n", .{w.buffered()});
        } else if (coaching and threats) {
            var cb: [1536]u8 = undefined;
            var w: Io.Writer = .fixed(&cb);
            const n = moves.items.len;
            const prev: ?coach.Prev = if (n >= 2) .{ .before = &history.items[n - 2], .move = moves.items[n - 2] } else null;
            coach.opponent(engine, &coach_ctx, &pos, move, prev, keys.items, &w) catch {};
            out.print("coach: {s}\n", .{w.buffered()});
        } else if (coaching and hints) {
            var cb: [1536]u8 = undefined;
            var w: Io.Writer = .fixed(&cb);
            if (coach.hintsOnly(&coach_ctx, &pos, move, &w) catch false) out.print("coach: {s}\n", .{w.buffered()});
        }
        pos = pos.makeMove(move);
        last = move;
    }
}

test "san" {
    const atk = @import("attacks.zig");
    atk.init();
    const pos = try Position.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("O-O", san(&pos, parseMove(&pos, "O-O").?, &buf));
    try std.testing.expectEqualStrings("Nxf7", san(&pos, parseMove(&pos, "e5f7").?, &buf));
    try std.testing.expectEqualStrings("Qxh3", san(&pos, parseMove(&pos, "Qxh3").?, &buf));
    try std.testing.expectEqualStrings("dxe6", san(&pos, parseMove(&pos, "dxe6").?, &buf));
    // Both rooks can reach d1: disambiguate by file.
    const p2 = try Position.fromFen("4k3/8/8/8/8/8/8/R4RK1 w - - 0 1");
    try std.testing.expectEqualStrings("Rad1", san(&p2, parseMove(&p2, "a1d1").?, &buf));
    try std.testing.expectEqualStrings("Rfd1", san(&p2, parseMove(&p2, "f1d1").?, &buf));
    try std.testing.expectEqualStrings("Ra8+", san(&p2, parseMove(&p2, "a1a8").?, &buf));
    try std.testing.expect(parseMove(&p2, "Rd1") == null); // ambiguous
}

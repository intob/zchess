//! UCI protocol front end. Searches run on a background thread so that
//! `stop` and `isready` are answered while thinking.

const std = @import("std");
const Io = std.Io;
const bb = @import("bitboard.zig");
const position = @import("position.zig");
const movegen = @import("movegen.zig");
const search = @import("search.zig");
const nnue = @import("nnue.zig");
const hce = @import("eval.zig");
const TT = @import("tt.zig").TT;
const Output = @import("output.zig").Output;
const strength = @import("strength.zig");

const Position = position.Position;
const Move = position.Move;

pub const NAME = "zchess 0.1";
pub const AUTHOR = "joey";

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Output,
    pos: Position,
    game_keys: std.ArrayList(u64) = .empty,
    tt: TT,
    hash_mb: usize = 64,
    net: ?*nnue.Network = null,
    use_nnue: bool = true,
    multipv: usize = 1,
    /// Safety margin (ms) kept off the clock for GUI and network delay.
    move_overhead: i64 = 30,
    /// UCI_LimitStrength / UCI_Elo (see strength.zig).
    limit_strength: bool = false,
    elo: u32 = 1500,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    pondering: std.atomic.Value(bool) = .init(false),
    /// Set only by the `stop` command (the search also sets `stop` itself).
    stop_cmd: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    searchers: std.ArrayList(*search.Searcher) = .empty,
    search_thread: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, out: *Output) !*Engine {
        const e = try gpa.create(Engine);
        e.* = .{ .gpa = gpa, .io = io, .out = out, .pos = Position.startpos(), .tt = try TT.init(gpa, 64) };
        e.net = try nnue.loadEmbedded(gpa);
        e.prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(Io.Clock.real.now(io).toNanoseconds()))));
        try e.setThreads(1);
        return e;
    }

    fn activeNet(e: *const Engine) ?*const nnue.Network {
        return if (e.use_nnue) e.net else null;
    }

    fn setThreads(e: *Engine, n: usize) !void {
        for (e.searchers.items) |s| e.gpa.destroy(s);
        e.searchers.clearRetainingCapacity();
        for (0..@max(n, 1)) |_| try e.searchers.append(e.gpa, try search.Searcher.create(e.gpa, e.io, &e.tt, e.activeNet(), &e.stop));
        for (e.searchers.items) |s| s.peers = e.searchers.items;
        e.searchers.items[0].out = e.out;
        e.searchers.items[0].multipv = e.multipv;
        e.searchers.items[0].pondering = &e.pondering;
    }

    fn waitSearch(e: *Engine) void {
        if (e.search_thread) |t| {
            t.join();
            e.search_thread = null;
        }
    }

    fn think(e: *Engine, limits: search.Limits) void {
        e.tt.newSearch();
        const main = e.searchers.items[0];
        if (e.limit_strength) return e.thinkLimited(main);
        var helpers: [256]?std.Thread = .{null} ** 256;
        for (e.searchers.items[1..], 0..) |s, i| {
            s.setPosition(&e.pos, e.game_keys.items);
            var hl = limits;
            hl.soft_ms = 0;
            hl.hard_ms = 0;
            hl.soft_nodes = 0;
            hl.nodes = 0;
            helpers[i] = std.Thread.spawn(.{}, helperMain, .{ s, hl }) catch null;
        }
        main.setPosition(&e.pos, e.game_keys.items);
        const r = main.search(limits);
        // UCI: no bestmove while pondering until ponderhit or stop.
        while (e.pondering.load(.monotonic) and !e.stop_cmd.load(.monotonic)) {
            e.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
        e.stop.store(true, .monotonic);
        for (helpers[0 .. e.searchers.items.len - 1]) |h| if (h) |t| t.join();
        var buf: [5]u8 = undefined;
        var pbuf: [5]u8 = undefined;
        // Expected reply, so the GUI can ponder on it during the opponent's time.
        const line = if (main.n_lines > 0) &main.lines[0] else null;
        if (line != null and line.?.move.eql(r.move) and line.?.pv_len >= 2) {
            e.out.print("bestmove {s} ponder {s}\n", .{ r.move.toUci(&buf), line.?.pv[1].toUci(&pbuf) });
        } else {
            e.out.print("bestmove {s}\n", .{r.move.toUci(&buf)});
        }
    }

    /// UCI_LimitStrength: one thread, a small search and a weighted pick
    /// among candidate moves. Time limits don't apply (it moves quickly).
    fn thinkLimited(e: *Engine, main: *search.Searcher) void {
        main.setPosition(&e.pos, e.game_keys.items);
        const c = strength.choose(main, e.prng.random(), e.elo);
        while (e.pondering.load(.monotonic) and !e.stop_cmd.load(.monotonic)) {
            e.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
        var buf: [5]u8 = undefined;
        var pbuf: [5]u8 = undefined;
        if (main.n_lines > c.line and main.lines[c.line].pv_len >= 2) {
            e.out.print("bestmove {s} ponder {s}\n", .{ c.result.move.toUci(&buf), main.lines[c.line].pv[1].toUci(&pbuf) });
        } else {
            e.out.print("bestmove {s}\n", .{c.result.move.toUci(&buf)});
        }
    }

    fn helperMain(s: *search.Searcher, limits: search.Limits) void {
        _ = s.search(limits);
    }

    fn setPositionCmd(e: *Engine, args: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, args, ' ');
        const kind = it.next() orelse return;
        var pos: Position = undefined;
        if (std.mem.eql(u8, kind, "startpos")) {
            pos = Position.startpos();
        } else if (std.mem.eql(u8, kind, "fen")) {
            var fen_buf: [128]u8 = undefined;
            var w: Io.Writer = .fixed(&fen_buf);
            var fields: usize = 0;
            while (it.peek()) |tok| {
                if (std.mem.eql(u8, tok, "moves")) break;
                _ = it.next();
                if (fields > 0) w.writeByte(' ') catch {};
                w.writeAll(tok) catch {};
                fields += 1;
            }
            pos = Position.fromFen(w.buffered()) catch {
                e.out.print("info string invalid fen\n", .{});
                return;
            };
        } else return;

        e.game_keys.clearRetainingCapacity();
        if (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "moves")) {
                while (it.next()) |mv| {
                    const m = movegen.parseUci(&pos, mv) orelse {
                        e.out.print("info string illegal move {s}\n", .{mv});
                        break;
                    };
                    e.game_keys.append(e.gpa, pos.key) catch {};
                    pos = pos.makeMove(m);
                }
            }
        }
        e.pos = pos;
    }

    fn goCmd(e: *Engine, args: []const u8) void {
        var limits = search.Limits{};
        var wtime: i64 = -1;
        var btime: i64 = -1;
        var winc: i64 = 0;
        var binc: i64 = 0;
        var movestogo: i64 = 0;
        var movetime: i64 = 0;
        var ponder = false;
        var it = std.mem.tokenizeScalar(u8, args, ' ');
        while (it.next()) |tok| {
            const v: i64 = if (it.peek()) |p| std.fmt.parseInt(i64, p, 10) catch 0 else 0;
            if (std.mem.eql(u8, tok, "wtime")) {
                wtime = v;
            } else if (std.mem.eql(u8, tok, "btime")) {
                btime = v;
            } else if (std.mem.eql(u8, tok, "winc")) {
                winc = v;
            } else if (std.mem.eql(u8, tok, "binc")) {
                binc = v;
            } else if (std.mem.eql(u8, tok, "movestogo")) {
                movestogo = v;
            } else if (std.mem.eql(u8, tok, "movetime")) {
                movetime = v;
            } else if (std.mem.eql(u8, tok, "depth")) {
                limits.depth = @intCast(std.math.clamp(v, 1, search.MAX_PLY - 1));
            } else if (std.mem.eql(u8, tok, "ponder")) {
                ponder = true;
            } else if (std.mem.eql(u8, tok, "nodes")) {
                limits.nodes = @intCast(@max(v, 1));
            }
        }

        const time = if (e.pos.side == bb.WHITE) wtime else btime;
        const inc = if (e.pos.side == bb.WHITE) winc else binc;
        if (movetime > 0) {
            limits.hard_ms = @max(movetime - e.move_overhead, 1);
        } else if (time >= 0) {
            const left = @max(time - e.move_overhead, 1);
            const mtg: i64 = if (movestogo > 0) @min(movestogo, 40) else 30;
            const base = @divTrunc(left, mtg) + @divTrunc(inc * 3, 4);
            limits.soft_ms = @max(@min(base, @divTrunc(left, 2)), 1);
            limits.hard_ms = @max(@min(base * 3, @divTrunc(left * 3, 4)), 1);
        }

        e.waitSearch();
        e.stop.store(false, .monotonic);
        e.stop_cmd.store(false, .monotonic);
        e.pondering.store(ponder, .monotonic);
        e.search_thread = std.Thread.spawn(.{}, think, .{ e, limits }) catch {
            e.out.print("info string failed to start search\n", .{});
            return;
        };
    }

    fn setOption(e: *Engine, args: []const u8) !void {
        // setoption name <Name> value <Value>
        const name_start = (std.mem.indexOf(u8, args, "name ") orelse return) + 5;
        const value_idx = std.mem.indexOf(u8, args, " value ");
        const name = std.mem.trim(u8, args[name_start .. value_idx orelse args.len], " ");
        const value = if (value_idx) |vi| std.mem.trim(u8, args[vi + 7 ..], " ") else "";

        if (std.ascii.eqlIgnoreCase(name, "Hash")) {
            const mb = std.math.clamp(std.fmt.parseInt(usize, value, 10) catch 64, 1, 65536);
            e.tt.deinit(e.gpa);
            e.tt = try TT.init(e.gpa, mb);
            e.hash_mb = mb;
        } else if (std.ascii.eqlIgnoreCase(name, "Threads")) {
            try e.setThreads(std.math.clamp(std.fmt.parseInt(usize, value, 10) catch 1, 1, 256));
        } else if (std.ascii.eqlIgnoreCase(name, "EvalFile")) {
            if (value.len == 0 or std.mem.eql(u8, value, "<embedded>")) return;
            const net = nnue.loadFile(e.gpa, e.io, value) catch |err| {
                e.out.print("info string failed to load {s}: {s}\n", .{ value, @errorName(err) });
                return;
            };
            e.net = net;
            e.use_nnue = true;
            try e.setThreads(e.searchers.items.len);
            e.out.print("info string loaded network {s}\n", .{value});
        } else if (std.ascii.eqlIgnoreCase(name, "UCI_LimitStrength")) {
            e.limit_strength = std.ascii.eqlIgnoreCase(value, "true");
        } else if (std.ascii.eqlIgnoreCase(name, "UCI_Elo")) {
            e.elo = std.math.clamp(std.fmt.parseInt(u32, value, 10) catch 1500, strength.MIN_ELO, strength.MAX_ELO);
        } else if (std.ascii.eqlIgnoreCase(name, "Move Overhead")) {
            e.move_overhead = std.math.clamp(std.fmt.parseInt(i64, value, 10) catch 30, 0, 5000);
        } else if (std.ascii.eqlIgnoreCase(name, "Clear Hash")) {
            e.tt.clear();
            for (e.searchers.items) |sr| sr.clearHistory();
        } else if (std.ascii.eqlIgnoreCase(name, "Ponder")) {
            // Nothing to configure: the GUI decides when to send `go ponder`.
        } else if (std.ascii.eqlIgnoreCase(name, "MultiPV")) {
            e.multipv = std.math.clamp(std.fmt.parseInt(usize, value, 10) catch 1, 1, search.MAX_MULTIPV);
            e.searchers.items[0].multipv = e.multipv;
        } else if (std.ascii.eqlIgnoreCase(name, "UseNNUE")) {
            e.use_nnue = std.ascii.eqlIgnoreCase(value, "true");
            try e.setThreads(e.searchers.items.len);
        }
    }

    pub fn loop(e: *Engine) !void {
        var in_buf: [16384]u8 = undefined;
        var fr = Io.File.stdin().reader(e.io, &in_buf);
        while (fr.interface.takeDelimiter('\n') catch null) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!try e.command(line)) break;
        }
        e.stop.store(true, .monotonic);
        e.waitSearch();
    }

    /// Handle one UCI command. Returns false on `quit`.
    pub fn command(e: *Engine, line: []const u8) !bool {
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const cmd = line[0 .. sp orelse line.len];
        const args = if (sp) |s| line[s + 1 ..] else "";

        if (std.mem.eql(u8, cmd, "uci")) {
            e.out.print("id name {s}\nid author {s}\n", .{ NAME, AUTHOR });
            e.out.print("option name Hash type spin default 64 min 1 max 65536\n", .{});
            e.out.print("option name Threads type spin default 1 min 1 max 256\n", .{});
            e.out.print("option name EvalFile type string default <embedded>\n", .{});
            e.out.print("option name UseNNUE type check default true\n", .{});
            e.out.print("option name MultiPV type spin default 1 min 1 max {d}\n", .{search.MAX_MULTIPV});
            e.out.print("option name Ponder type check default false\n", .{});
            e.out.print("option name Move Overhead type spin default 30 min 0 max 5000\n", .{});
            e.out.print("option name Clear Hash type button\n", .{});
            e.out.print("option name UCI_LimitStrength type check default false\n", .{});
            e.out.print("option name UCI_Elo type spin default 1500 min {d} max {d}\n", .{ strength.MIN_ELO, strength.MAX_ELO });
            e.out.print("uciok\n", .{});
        } else if (std.mem.eql(u8, cmd, "isready")) {
            e.out.print("readyok\n", .{});
        } else if (std.mem.eql(u8, cmd, "ucinewgame")) {
            e.waitSearch();
            e.tt.clear();
            for (e.searchers.items) |s| s.clearHistory();
        } else if (std.mem.eql(u8, cmd, "position")) {
            e.waitSearch();
            e.setPositionCmd(args);
        } else if (std.mem.eql(u8, cmd, "go")) {
            e.goCmd(args);
        } else if (std.mem.eql(u8, cmd, "stop")) {
            e.stop_cmd.store(true, .monotonic);
            e.stop.store(true, .monotonic);
            e.waitSearch();
        } else if (std.mem.eql(u8, cmd, "ponderhit")) {
            e.searchers.items[0].ponderhit();
        } else if (std.mem.eql(u8, cmd, "setoption")) {
            e.waitSearch();
            try e.setOption(args);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            return false;
        } else if (std.mem.eql(u8, cmd, "d")) {
            var buf: [2048]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            e.pos.print(&w) catch {};
            e.out.print("{s}", .{w.buffered()});
        } else if (std.mem.eql(u8, cmd, "eval")) {
            const h = hce.evaluate(&e.pos);
            if (e.net) |n| {
                e.out.print("hce {d} nnue {d} (side to move)\n", .{ h, nnue.evaluateFresh(n, &e.pos) });
            } else e.out.print("hce {d} (side to move, no network loaded)\n", .{h});
        } else if (std.mem.eql(u8, cmd, "perft")) {
            const depth = std.fmt.parseInt(u32, std.mem.trim(u8, args, " "), 10) catch 5;
            const t0 = Io.Clock.awake.now(e.io);
            var list = movegen.MoveList{};
            movegen.generate(&e.pos, &list, .all);
            var total: u64 = 0;
            for (list.slice()) |m| {
                const c = e.pos.makeMove(m);
                const n = if (depth > 1) movegen.perft(&c, depth - 1) else 1;
                total += n;
                var b: [5]u8 = undefined;
                e.out.print("{s}: {d}\n", .{ m.toUci(&b), n });
            }
            const ms = t0.durationTo(Io.Clock.awake.now(e.io)).toMilliseconds();
            e.out.print("\nnodes {d} time {d}ms nps {d}\n", .{ total, ms, total * 1000 / @as(u64, @intCast(@max(ms, 1))) });
        } else if (cmd.len > 0) {
            e.out.print("info string unknown command {s}\n", .{cmd});
        }
        return true;
    }
};

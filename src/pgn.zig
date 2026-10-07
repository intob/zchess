//! Minimal streaming PGN reader shared by `book` and `review`.

const std = @import("std");
const Io = std.Io;

pub const Header = struct { key: []const u8, value: []const u8 };

pub const Game = struct {
    headers: []const Header,
    movetext: []const u8,

    pub fn header(g: *const Game, key: []const u8) ?[]const u8 {
        for (g.headers) |h| if (std.mem.eql(u8, h.key, key)) return h.value;
        return null;
    }

    /// Standard chess from the normal start position (no variants, no SetUp/FEN).
    pub fn isStandard(g: *const Game) bool {
        if (g.header("Variant")) |v| if (!std.ascii.eqlIgnoreCase(v, "standard")) return false;
        if (g.header("SetUp")) |v| if (std.mem.eql(u8, v, "1")) return false;
        return g.header("FEN") == null;
    }
};

/// Calls `onGame(ctx, &game)` for every game in `r`. Slices in `game` are only
/// valid during the callback.
pub fn readGames(gpa: std.mem.Allocator, r: *Io.Reader, ctx: anytype, comptime onGame: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var headers: std.ArrayList(Header) = .empty;
    var movetext: std.ArrayList(u8) = .empty;
    var in_moves = false;
    var skip_game = false;

    while (true) {
        const raw = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Absurdly long line: drop it and the game it belongs to.
                _ = try r.discardDelimiterInclusive('\n');
                skip_game = true;
                continue;
            },
            else => return err,
        } orelse break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            if (in_moves) {
                if (!skip_game) try onGame(ctx, &Game{ .headers = headers.items, .movetext = movetext.items });
                _ = arena.reset(.retain_capacity);
                headers = .empty;
                movetext = .empty;
                in_moves = false;
                skip_game = false;
            }
            const a = arena.allocator();
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const q1 = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const q2 = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue;
            if (q2 <= q1 or sp < 2) continue;
            try headers.append(a, .{ .key = try a.dupe(u8, line[1..sp]), .value = try a.dupe(u8, line[q1 + 1 .. q2]) });
            continue;
        }
        if (line.len == 0) continue;
        in_moves = true;
        const a = arena.allocator();
        try movetext.appendSlice(a, line);
        try movetext.append(a, ' ');
    }
    if (in_moves and !skip_game) try onGame(ctx, &Game{ .headers = headers.items, .movetext = movetext.items });
}

/// Yields the SAN move tokens of PGN movetext, skipping { comments },
/// ( variations ), $NAGs and move numbers. Stops at the result token.
pub const SanIterator = struct {
    it: std.mem.TokenIterator(u8, .any),
    depth: usize = 0,

    pub fn init(movetext: []const u8) SanIterator {
        return .{ .it = std.mem.tokenizeAny(u8, movetext, " \t\r\n") };
    }

    pub fn next(s: *SanIterator) ?[]const u8 {
        while (s.it.next()) |raw| {
            var tok = raw;
            // Comments and variations; tokens may straddle the brackets.
            if (s.depth > 0 or tok[0] == '{' or tok[0] == '(') {
                for (tok) |ch| switch (ch) {
                    '{', '(' => s.depth += 1,
                    '}', ')' => s.depth -|= 1,
                    else => {},
                };
                continue;
            }
            if (tok[0] == '$') continue;
            if (std.mem.eql(u8, tok, "*") or std.mem.eql(u8, tok, "1-0") or std.mem.eql(u8, tok, "0-1") or std.mem.eql(u8, tok, "1/2-1/2")) return null;
            if (std.mem.startsWith(u8, tok, "0-0")) return tok; // castling written with zeros
            // Move numbers: "12." or "12..." possibly glued to the move ("12.e4").
            if (std.ascii.isDigit(tok[0])) {
                const dot = std.mem.lastIndexOfScalar(u8, tok, '.') orelse continue;
                tok = tok[dot + 1 ..];
                if (tok.len == 0) continue;
            }
            return tok;
        }
        return null;
    }
};

test "san iterator" {
    var it = SanIterator.init("1. e4 {[%clk 0:09:58]} 1... e5 2.Nf3 (2. f4 exf4) 2... Nc6 $1 3. 0-0 {a\ncomment} 1-0");
    const want = [_][]const u8{ "e4", "e5", "Nf3", "Nc6", "0-0" };
    for (want) |w| try std.testing.expectEqualStrings(w, it.next().?);
    try std.testing.expect(it.next() == null);
}

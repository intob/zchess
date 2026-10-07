//! Small helpers shared by the command-line tools.

const std = @import("std");
const nnue = @import("nnue.zig");

pub const Parser = struct {
    args: []const [:0]const u8,
    i: usize = 0,

    pub fn next(p: *Parser) ?[]const u8 {
        if (p.i >= p.args.len) return null;
        p.i += 1;
        return p.args[p.i - 1];
    }

    /// If `arg` is `name`, consume and return the following value.
    pub fn flag(p: *Parser, arg: []const u8, name: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, arg, name)) return null;
        return p.next() orelse {
            std.debug.print("missing value for {s}\n", .{name});
            std.process.exit(2);
        };
    }

    pub fn int(p: *Parser, comptime T: type, arg: []const u8, name: []const u8) ?T {
        const v = p.flag(arg, name) orelse return null;
        return std.fmt.parseInt(T, v, 10) catch {
            std.debug.print("invalid number for {s}: {s}\n", .{ name, v });
            std.process.exit(2);
        };
    }

    pub fn float(p: *Parser, arg: []const u8, name: []const u8) ?f32 {
        const v = p.flag(arg, name) orelse return null;
        return std.fmt.parseFloat(f32, v) catch {
            std.debug.print("invalid number for {s}: {s}\n", .{ name, v });
            std.process.exit(2);
        };
    }
};

/// "" -> embedded network if present, else HCE. "hce" -> HCE. Otherwise a file.
pub fn loadNet(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?*const nnue.Network {
    if (std.mem.eql(u8, path, "hce")) return null;
    if (path.len == 0) return try nnue.loadEmbedded(gpa);
    return nnue.loadFile(gpa, io, path) catch |err| {
        std.debug.print("failed to load network {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
}

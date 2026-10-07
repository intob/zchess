//! Thread-safe line output for UCI (search thread and input thread both print).

const std = @import("std");
const Io = std.Io;

pub const Output = struct {
    io: Io,
    writer: *Io.Writer,
    mutex: Io.Mutex = .init,

    pub fn print(self: *Output, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
    }
};

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // A chess engine is useless in Debug, so default to ReleaseFast.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseFast)") orelse .ReleaseFast;

    // Optionally embed a trained network: zig build -Dnet=nets/gen3.nnue
    const net_path = b.option([]const u8, "net", "NNUE file to embed as the default evaluation");

    // Network shape; nets only load into a binary built with the same shape.
    // With -Dnet both default to what that file's header says.
    const shape = if (net_path) |p| netShape(b, p) else NetShape{};
    const hidden = b.option(u32, "hidden", "NNUE hidden layer size (default 256 or the -Dnet's, multiple of 32)") orelse shape.hidden;
    const king_buckets = b.option(u32, "king-buckets", "NNUE king buckets: 0 (none, unmirrored), 1, 4, 8 or 16 (default 0 or the -Dnet's)") orelse shape.king_buckets;

    // Opening names and the strong players' move tree for the coach
    // (zchess openings); embedded when the file exists.
    const openings_path: ?[]const u8 = b.option([]const u8, "openings", "Opening book for the coach (default data/openings.bin if it exists)") orelse
        if (fileExists(b, "data/openings.bin")) @as([]const u8, "data/openings.bin") else null;

    const options = b.addOptions();
    options.addOption(bool, "has_net", net_path != null);
    options.addOption(bool, "has_openings", openings_path != null);
    options.addOption(u32, "hidden", hidden);
    options.addOption(u32, "king_buckets", king_buckets);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    if (net_path) |p| mod.addAnonymousImport("default_net", .{ .root_source_file = b.path(p) });
    if (openings_path) |p| mod.addAnonymousImport("openings", .{ .root_source_file = b.path(p) });

    const exe = b.addExecutable(.{ .name = "zchess", .root_module = mod });
    b.installArtifact(exe);

    // Fingerprint art: the new binary hashes itself, plays a short game seeded
    // by the hash and renders the final position to zig-out/zchess.png.
    // Only possible when the binary can run on this machine.
    const want_art = b.option(bool, "art", "Render zig-out/zchess.png from the binary's hash (default true)") orelse true;
    if (want_art and target.query.isNative()) {
        const art = b.addRunArtifact(exe);
        art.addArg("art");
        art.addFileArg(exe.getEmittedBin());
        const png = art.addOutputFileArg("zchess.png");
        b.getInstallStep().dependOn(&b.addInstallFile(png, "zchess.png").step);
    }

    // Keep zchess's En Croissant entry (version, rating, settings) in step with
    // what was just built; a no-op unless an entry points at this binary.
    const want_ec = b.option(bool, "ec", "Update the En Croissant engine entry after building (default true)") orelse true;
    if (want_ec and target.query.isNative()) {
        const ec = b.addSystemCommand(&.{"python3"});
        ec.addFileArg(b.path("scripts/ec-engine.py"));
        ec.addFileArg(exe.getEmittedBin());
        ec.addArg(b.getInstallPath(.bin, exe.out_filename));
        if (net_path) |p| ec.addArg(p);
        b.getInstallStep().dependOn(&ec.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the engine").dependOn(&run_cmd.step);

    // Tests keep safety checks on (overflow, bounds) but stay fast enough for perft.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimization mode for tests (default ReleaseSafe)") orelse .ReleaseSafe,
    });
    test_mod.addOptions("build_options", options);
    if (net_path) |p| test_mod.addAnonymousImport("default_net", .{ .root_source_file = b.path(p) });
    if (openings_path) |p| test_mod.addAnonymousImport("openings", .{ .root_source_file = b.path(p) });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

const NetShape = struct { hidden: u32 = 256, king_buckets: u32 = 0 };

/// Hidden size and king buckets from a .nnue header (see src/nnue.zig).
fn netShape(b: *std.Build, path: []const u8) NetShape {
    const io = b.graph.io;
    const f = b.build_root.handle.openFile(io, path, .{}) catch return .{};
    defer f.close(io);
    var h: [20]u8 = undefined;
    const n = f.readPositionalAll(io, &h, 0) catch return .{};
    if (n < 16 or !std.mem.eql(u8, h[0..4], "ZCNN")) return .{};
    const version = std.mem.readInt(u32, h[4..8], .little);
    return .{
        .hidden = std.mem.readInt(u32, h[8..12], .little),
        .king_buckets = if (version >= 2 and n == 20) std.mem.readInt(u32, h[16..20], .little) else 0,
    };
}

fn fileExists(b: *std.Build, path: []const u8) bool {
    const io = b.graph.io;
    const f = b.build_root.handle.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

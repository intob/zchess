const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // A chess engine is useless in Debug, so default to ReleaseFast.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseFast)") orelse .ReleaseFast;

    // Optionally embed a trained network: zig build -Dnet=nets/gen3.nnue
    const net_path = b.option([]const u8, "net", "NNUE file to embed as the default evaluation");

    // Network width; nets only load into a binary built with the same size.
    const hidden = b.option(u32, "hidden", "NNUE hidden layer size (default 256, multiple of 16)") orelse 256;

    const options = b.addOptions();
    options.addOption(bool, "has_net", net_path != null);
    options.addOption(u32, "hidden", hidden);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    if (net_path) |p| mod.addAnonymousImport("default_net", .{ .root_source_file = b.path(p) });

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
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

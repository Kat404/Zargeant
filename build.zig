const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{} });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or fast compilation (Debug, ReleaseSafe, ReleaseFast)",
    ) orelse .Debug;

    // lib: harness (static library)
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    const lib = b.addLibrary(.{
        .name = "harness",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // exe: zargeant
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    exe_mod.single_threaded = false;
    const exe = b.addExecutable(.{
        .name = "zargeant",
        .root_module = exe_mod,
    });
    exe.lto = if (optimize == .ReleaseFast) .full else null;
    exe.root_module.strip = optimize == .ReleaseFast;
    b.installArtifact(exe);

    // test step
    const test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    test_mod.addIncludePath(b.path("test"));
    const test_step = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(test_step);
    const test_decl = b.step("test", "Run unit tests");
    test_decl.dependOn(&run_test.step);
}

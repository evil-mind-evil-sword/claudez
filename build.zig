const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const mod = b.addModule("claudez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library artifact for linking
    const lib = b.addStaticLibrary(.{
        .name = "claudez",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Simple query example
    const simple_query_exe = b.addExecutable(.{
        .name = "simple_query",
        .root_source_file = b.path("examples/simple_query.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_query_exe.root_module.addImport("claudez", mod);
    b.installArtifact(simple_query_exe);

    // Streaming example
    const streaming_exe = b.addExecutable(.{
        .name = "streaming",
        .root_source_file = b.path("examples/streaming.zig"),
        .target = target,
        .optimize = optimize,
    });
    streaming_exe.root_module.addImport("claudez", mod);
    b.installArtifact(streaming_exe);

    // Tests
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}

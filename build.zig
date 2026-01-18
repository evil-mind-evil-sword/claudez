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

    // Simple query example
    const simple_query_exe = b.addExecutable(.{
        .name = "simple_query",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple_query.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "claudez", .module = mod },
            },
        }),
    });
    b.installArtifact(simple_query_exe);

    // Streaming example
    const streaming_exe = b.addExecutable(.{
        .name = "streaming",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/streaming.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "claudez", .module = mod },
            },
        }),
    });
    b.installArtifact(streaming_exe);

    // Shared library for FFI (C ABI)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "claudez",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });
    lib.root_module.pic = true;
    b.installArtifact(lib);

    // Static library for FFI
    const static_lib = b.addLibrary(.{
        .name = "claudez",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(static_lib);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}

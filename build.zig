const std = @import("std");

fn libdillPath(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    const filename = switch (os) {
        .macos => switch (arch) {
            .aarch64 => "vendor/libdill-aarch64-macos.a",
            .x86_64 => "vendor/libdill-x86_64-macos.a",
            else => "vendor/libdill.a",
        },
        .linux => switch (arch) {
            .aarch64 => "vendor/libdill-aarch64-linux.a",
            .x86_64 => "vendor/libdill-x86_64-linux.a",
            else => "vendor/libdill.a",
        },
        else => "vendor/libdill.a",
    };

    return b.path(filename);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (for use by other projects)
    const lib_mod = b.addModule("zsp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zsp", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Dill executable (libdill examples)
    const dill_exe = b.addExecutable(.{
        .name = "dill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dill.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    dill_exe.root_module.addIncludePath(b.path("vendor"));
    dill_exe.root_module.addObjectFile(libdillPath(b, target));
    b.installArtifact(dill_exe);

    const run_dill = b.addRunArtifact(dill_exe);
    run_dill.step.dependOn(b.getInstallStep());
    const dill_step = b.step("dill", "Run dill example");
    dill_step.dependOn(&run_dill.step);

    // Tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Check step
    const exe_check = b.addExecutable(.{
        .name = "zsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check = b.step("check", "Check if zsp compiles");
    check.dependOn(&exe_check.step);
}

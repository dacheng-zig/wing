const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const talon_dep = b.dependency("talon", .{
        .target = target,
        .optimize = optimize,
    });
    const talon_mod = talon_dep.module("talon");
    const zio_mod = talon_dep.builder.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    }).module("zio");

    const wing_mod = b.addModule("wing", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "talon", .module = talon_mod },
            .{ .name = "zio", .module = zio_mod },
        },
    });

    // Tests
    const wing_tests = b.addTest(.{ .root_module = wing_mod });
    const run_wing_tests = b.addRunArtifact(wing_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_wing_tests.step);

    for ([_][]const u8{ "tests/integration_test.zig", "tests/zero_alloc_test.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "wing", .module = wing_mod },
                    .{ .name = "talon", .module = talon_mod },
                    .{ .name = "zio", .module = zio_mod },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Examples
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wing", .module = wing_mod },
                .{ .name = "talon", .module = talon_mod },
                .{ .name = "zio", .module = zio_mod },
            },
        }),
    });
    b.installArtifact(demo);
    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_demo.addArgs(args);
    const run_step = b.step("run-demo", "Run the framework demo");
    run_step.dependOn(&run_demo.step);
}

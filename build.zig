const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import shinydb-zig-client as a dependency
    const shinydb_client = b.dependency("shinydb_zig_client", .{
        .target = target,
        .optimize = optimize,
    });

    // Main loader executable
    const exe = b.addExecutable(.{
        .name = "salesdb-loader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shinydb_zig_client", .module = shinydb_client.module("shinydb_zig_client") },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the data loader");
    run_step.dependOn(&run_cmd.step);

    // Sales demo executable
    const demo_exe = b.addExecutable(.{
        .name = "sales-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sales_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shinydb_zig_client", .module = shinydb_client.module("shinydb_zig_client") },
            },
        }),
    });

    b.installArtifact(demo_exe);

    // Run demo step
    const demo_run_cmd = b.addRunArtifact(demo_exe);
    demo_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        demo_run_cmd.addArgs(args);
    }

    const demo_run_step = b.step("run-demo", "Run the sales demo");
    demo_run_step.dependOn(&demo_run_cmd.step);

    // Query test executable
    const test_exe = b.addExecutable(.{
        .name = "query-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/query_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shinydb_zig_client", .module = shinydb_client.module("shinydb_zig_client") },
            },
        }),
    });

    b.installArtifact(test_exe);

    // Run tests step
    const test_run_cmd = b.addRunArtifact(test_exe);
    test_run_cmd.step.dependOn(b.getInstallStep());

    const test_run_step = b.step("test", "Run query correctness tests");
    test_run_step.dependOn(&test_run_cmd.step);
}

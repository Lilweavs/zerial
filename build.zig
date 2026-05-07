const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // create module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // add vaxis dependency to module
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const serial = b.dependency("serial", .{
        .target = target,
        .optimize = optimize,
    });

    const zon_module = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });
    exe_mod.addImport("build.zig.zon", zon_module);

    exe_mod.addImport("vaxis", vaxis.module("vaxis"));
    exe_mod.addImport("serial", serial.module("serial"));

    check_mod.addImport("vaxis", vaxis.module("vaxis"));
    check_mod.addImport("serial", serial.module("serial"));

    //create executable
    const exe = b.addExecutable(.{
        .name = "zerial",
        .root_module = exe_mod,
    });

    const exe_check = b.addExecutable(.{
        .name = "zerial",
        .root_module = exe_mod,
    });

    const check = b.step("check", "Check if tui-serial compiles");
    check.dependOn(&exe_check.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

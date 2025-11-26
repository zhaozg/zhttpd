const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    
    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
    });
    
    const grapzig = b.dependency("grapzig", .{
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zhttpd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Add dependencies to executable
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addImport("ziglua", ziglua.module("zlua"));
    exe.root_module.addImport("grapzig", grapzig.module("grapzig"));

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the web server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}

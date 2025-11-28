const std = @import("std");

/// Lua language/engine options
pub const LuaLang = enum {
    lua54, // Standard Lua 5.4 (default, stable)
    luajit, // LuaJIT (faster, JIT compilation)
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Lua engine selection option
    // LuaJIT provides better performance through JIT compilation
    // Note: LuaJIT may have build issues on some platforms (especially cross-compilation)
    const lua_lang = b.option(LuaLang, "lua-lang", "Lua language/engine to use (lua54 or luajit)") orelse .lua54;

    // Dependencies
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // Configure ziglua with the selected Lua engine
    // We need to use separate dependency calls because .lang requires comptime value
    const ziglua = if (lua_lang == .luajit)
        b.dependency("ziglua", .{
            .target = target,
            .optimize = optimize,
            .lang = .luajit,
        })
    else
        b.dependency("ziglua", .{
            .target = target,
            .optimize = optimize,
            .lang = .lua54,
        });

    const grapzig = b.dependency("grapzig", .{
        .target = target,
        .optimize = optimize,
    });

    // Build configuration options to expose to the runtime
    const build_options = b.addOptions();
    build_options.addOption(LuaLang, "lua_lang", lua_lang);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zhttpd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add build options to executable
    exe.root_module.addOptions("build_options", build_options);

    // Add dependencies to executable
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    // Note: ziglua's internal module is named "zlua"; we import it as "ziglua" in our code
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

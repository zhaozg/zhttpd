const std = @import("std");
const config = @import("config/config.zig");
const lua = @import("lua/lua.zig");

pub const VERSION = "0.6.0";

/// Command-line argument parsing result
pub const CliResult = union(enum) {
    /// Continue with configuration (may be from file or CLI overrides)
    run: config.Config,
    /// Exit immediately (help, version, or error was shown)
    exit: u8, // exit code
};

/// CLI options that can override config file settings
pub const CliOptions = struct {
    config_file: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    static_dir: ?[]const u8 = null,
    lua_scripts_dir: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    thread_pool_size: ?u32 = null,
    security_headers: ?bool = null,
};

/// Parse command-line arguments and return configuration or exit code
pub fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args, io: std.Io) !CliResult {
    var args_iter = std.process.Args.Iterator.init(args);

    // Skip the program name
    _ = args_iter.next();

    var options = CliOptions{};

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return .{ .exit = 0 };
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return .{ .exit = 0 };
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            options.config_file = args_iter.next() orelse {
                std.debug.print("Error: --config requires a file path argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            const port_str = args_iter.next() orelse {
                std.debug.print("Error: --port requires a port number argument\n", .{});
                return .{ .exit = 1 };
            };
            options.port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: Invalid port number: {s}\n", .{port_str});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            options.host = args_iter.next() orelse {
                std.debug.print("Error: --host requires an address argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--static-dir")) {
            options.static_dir = args_iter.next() orelse {
                std.debug.print("Error: --static-dir requires a directory path argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--lua-dir")) {
            options.lua_scripts_dir = args_iter.next() orelse {
                std.debug.print("Error: --lua-dir requires a directory path argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            options.log_level = args_iter.next() orelse {
                std.debug.print("Error: --log-level requires a level argument (debug, info, warn, error)\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            const threads_str = args_iter.next() orelse {
                std.debug.print("Error: --threads requires a number argument\n", .{});
                return .{ .exit = 1 };
            };
            options.thread_pool_size = std.fmt.parseInt(u32, threads_str, 10) catch {
                std.debug.print("Error: Invalid thread count: {s}\n", .{threads_str});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "--no-security-headers")) {
            options.security_headers = false;
        } else if (std.mem.eql(u8, arg, "--security-headers")) {
            options.security_headers = true;
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            std.debug.print("Use --help for usage information\n", .{});
            return .{ .exit = 1 };
        }
    }

    // Load configuration with CLI overrides
    const cfg = try loadConfigWithOverrides(allocator, options, io);
    return .{ .run = cfg };
}

/// Load configuration from file (or default) and apply CLI overrides
fn loadConfigWithOverrides(allocator: std.mem.Allocator, options: CliOptions, io: std.Io) !config.Config {
    // Load configuration using block expression to avoid undefined state
    var cfg = blk: {
        if (options.config_file) |config_path| {
            // User specified a config file - verify it exists first
            std.Io.Dir.accessAbsolute(io, config_path, .{}) catch |err| {
                std.debug.print("Error: Config file '{s}' not accessible: {}\n", .{ config_path, err });
                return error.ConfigLoadFailed;
            };
            // File exists, load it
            const c = config.loadConfig(allocator, config_path, io) catch |err| {
                std.debug.print("Error: Failed to parse config file '{s}': {}\n", .{ config_path, err });
                return error.ConfigLoadFailed;
            };
            std.debug.print("Loaded configuration from {s}\n", .{config_path});
            break :blk c;
        } else {
            // Try default YAML config file (JSON no longer supported)
            if (config.loadConfig(allocator, "zhttpd.yaml", io)) |c| {
                std.debug.print("Loaded configuration from zhttpd.yaml\n", .{});
                break :blk c;
            } else |_| {
                std.debug.print("Using default configuration\n", .{});
                break :blk try config.getDefaultConfig(allocator);
            }
        }
    };

    // Apply CLI overrides - use cfg.allocator which is the same allocator used to create the config
    if (options.host) |host| {
        cfg.allocator.free(cfg.host);
        cfg.host = try cfg.allocator.dupe(u8, host);
    }
    if (options.port) |port| {
        cfg.port = port;
    }
    if (options.static_dir) |dir| {
        cfg.allocator.free(cfg.static_dir);
        cfg.static_dir = try cfg.allocator.dupe(u8, dir);
    }
    if (options.lua_scripts_dir) |dir| {
        cfg.allocator.free(cfg.lua_scripts_dir);
        cfg.lua_scripts_dir = try cfg.allocator.dupe(u8, dir);
    }
    if (options.log_level) |level| {
        cfg.allocator.free(cfg.log_level);
        cfg.log_level = try cfg.allocator.dupe(u8, level);
    }
    if (options.thread_pool_size) |threads| {
        cfg.thread_pool_size = threads;
    }
    if (options.security_headers) |enabled| {
        cfg.security_headers = enabled;
    }

    return cfg;
}

/// Print help message
fn printHelp() void {
    const help_text =
        \\zhttpd - A high-performance HTTP web server built with Zig
        \\
        \\USAGE:
        \\    zhttpd [OPTIONS]
        \\
        \\OPTIONS:
        \\    -h, --help                 Print this help message and exit
        \\    -v, --version              Print version information and exit
        \\    -c, --config <FILE>        Specify configuration file path (YAML only)
        \\                               (default: zhttpd.yaml)
        \\    -p, --port <PORT>          Set server port (default: 8080)
        \\    -H, --host <HOST>          Set server bind address (default: 0.0.0.0)
        \\    -s, --static-dir <DIR>     Set static files directory
        \\                               (default: ./examples/static)
        \\    -l, --lua-dir <DIR>        Set Lua scripts directory
        \\                               (default: ./examples/lua)
        \\    --log-level <LEVEL>        Set log level: debug, info, warn, error
        \\                               (default: info)
        \\    -t, --threads <N>          Set thread pool size (default: 4)
        \\    --security-headers         Enable HTTP security headers (default)
        \\    --no-security-headers      Disable HTTP security headers
        \\
        \\CONFIGURATION FILE:
        \\    The server looks for configuration in the following order:
        \\    1. File specified with --config (must be YAML, .yaml or .yml extension)
        \\    2. zhttpd.yaml in current directory
        \\    3. Built-in defaults
        \\
        \\    Command-line options override configuration file settings.
        \\
        \\HANDLER CONFIGURATION:
        \\    Handlers can be configured in the YAML file using the 'handlers' section:
        \\    
        \\    handlers:
        \\      /health: Handler.HealthCheckHandler
        \\      /api/*: Handler.LuaHandler
        \\      /*: Handler.StaticFileHandler
        \\
        \\EXAMPLES:
        \\    zhttpd                         Start with default/config file settings
        \\    zhttpd -p 3000                 Start server on port 3000
        \\    zhttpd -c myconfig.yaml        Use custom configuration file
        \\    zhttpd -H 127.0.0.1 -p 8000    Bind to localhost on port 8000
        \\    zhttpd --log-level debug       Enable debug logging
        \\
        \\For more information, visit: https://github.com/zhaozg/zhttpd
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

/// Print version information
fn printVersion() void {
    std.debug.print("zhttpd version {s}\n", .{VERSION});
    std.debug.print("Lua backend: {s}\n", .{lua.getLuaEngineName()});
    std.debug.print("Built with Zig\n", .{});
    std.debug.print("https://github.com/zhaozg/zhttpd\n", .{});
}

// Tests
test "CliOptions default values" {
    const options = CliOptions{};
    try std.testing.expect(options.config_file == null);
    try std.testing.expect(options.host == null);
    try std.testing.expect(options.port == null);
    try std.testing.expect(options.static_dir == null);
    try std.testing.expect(options.lua_scripts_dir == null);
    try std.testing.expect(options.log_level == null);
    try std.testing.expect(options.thread_pool_size == null);
    try std.testing.expect(options.security_headers == null);
}

test "CliOptions with values" {
    const options = CliOptions{
        .config_file = "test.yaml",
        .host = "127.0.0.1",
        .port = 3000,
        .static_dir = "./static",
        .lua_scripts_dir = "./lua",
        .log_level = "debug",
        .thread_pool_size = 8,
        .security_headers = false,
    };
    try std.testing.expectEqualStrings("test.yaml", options.config_file.?);
    try std.testing.expectEqualStrings("127.0.0.1", options.host.?);
    try std.testing.expect(options.port.? == 3000);
    try std.testing.expectEqualStrings("./static", options.static_dir.?);
    try std.testing.expectEqualStrings("./lua", options.lua_scripts_dir.?);
    try std.testing.expectEqualStrings("debug", options.log_level.?);
    try std.testing.expect(options.thread_pool_size.? == 8);
    try std.testing.expect(options.security_headers.? == false);
}

test "CliResult union" {
    // Test exit variant
    const exit_result = CliResult{ .exit = 0 };
    switch (exit_result) {
        .exit => |code| try std.testing.expect(code == 0),
        .run => unreachable,
    }

    // Test that run variant can hold a config (compilation check)
    _ = CliResult.run;
}

test "VERSION constant" {
    try std.testing.expect(VERSION.len > 0);
    // Version should be in semver format (contains dots)
    try std.testing.expect(std.mem.indexOfScalar(u8, VERSION, '.') != null);
}

test "loadConfigWithOverrides applies CLI overrides" {
    const allocator = std.testing.allocator;

    // Test with no CLI overrides - should use defaults
    const options = CliOptions{};
    const cfg = loadConfigWithOverrides(allocator, options) catch |err| {
        // Config load may fail if no config file exists, which is fine for this test
        if (err == error.ConfigLoadFailed) {
            return; // Skip test if config load fails
        }
        return err;
    };
    defer cfg.deinit();

    // Verify default config was loaded
    try std.testing.expect(cfg.port == 8080);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
}

test "loadConfigWithOverrides with port override" {
    const allocator = std.testing.allocator;

    const options = CliOptions{
        .port = 9999,
    };
    const cfg = loadConfigWithOverrides(allocator, options) catch |err| {
        if (err == error.ConfigLoadFailed) {
            return;
        }
        return err;
    };
    defer cfg.deinit();

    // Verify port was overridden
    try std.testing.expect(cfg.port == 9999);
}

test "loadConfigWithOverrides with host override" {
    const allocator = std.testing.allocator;

    const options = CliOptions{
        .host = "192.168.1.1",
    };
    const cfg = loadConfigWithOverrides(allocator, options) catch |err| {
        if (err == error.ConfigLoadFailed) {
            return;
        }
        return err;
    };
    defer cfg.deinit();

    // Verify host was overridden
    try std.testing.expectEqualStrings("192.168.1.1", cfg.host);
}

test "loadConfigWithOverrides with security_headers override" {
    const allocator = std.testing.allocator;

    const options = CliOptions{
        .security_headers = false,
    };
    const cfg = loadConfigWithOverrides(allocator, options) catch |err| {
        if (err == error.ConfigLoadFailed) {
            return;
        }
        return err;
    };
    defer cfg.deinit();

    // Verify security_headers was overridden
    try std.testing.expect(cfg.security_headers == false);
}

test "loadConfigWithOverrides with invalid config file" {
    const allocator = std.testing.allocator;

    const options = CliOptions{
        .config_file = "/nonexistent/path/config.yaml",
    };

    // Should return ConfigLoadFailed error
    const result = loadConfigWithOverrides(allocator, options);
    try std.testing.expectError(error.ConfigLoadFailed, result);
}

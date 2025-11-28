const std = @import("std");
const config = @import("config/config.zig");

pub const VERSION = "0.1.2";

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
pub fn parseArgs(allocator: std.mem.Allocator) !CliResult {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip the program name
    _ = args.next();

    var options = CliOptions{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return .{ .exit = 0 };
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return .{ .exit = 0 };
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            options.config_file = args.next() orelse {
                std.debug.print("Error: --config requires a file path argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse {
                std.debug.print("Error: --port requires a port number argument\n", .{});
                return .{ .exit = 1 };
            };
            options.port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: Invalid port number: {s}\n", .{port_str});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            options.host = args.next() orelse {
                std.debug.print("Error: --host requires an address argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--static-dir")) {
            options.static_dir = args.next() orelse {
                std.debug.print("Error: --static-dir requires a directory path argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--lua-dir")) {
            options.lua_scripts_dir = args.next() orelse {
                std.debug.print("Error: --lua-dir requires a directory path argument\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            options.log_level = args.next() orelse {
                std.debug.print("Error: --log-level requires a level argument (debug, info, warn, error)\n", .{});
                return .{ .exit = 1 };
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            const threads_str = args.next() orelse {
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
    const cfg = try loadConfigWithOverrides(allocator, options);
    return .{ .run = cfg };
}

/// Load configuration from file (or default) and apply CLI overrides
fn loadConfigWithOverrides(allocator: std.mem.Allocator, options: CliOptions) !config.Config {
    // Determine config file to use
    var cfg: config.Config = undefined;
    var config_source: []const u8 = "default";

    if (options.config_file) |config_path| {
        // User specified a config file
        cfg = config.loadConfig(allocator, config_path) catch |err| {
            std.debug.print("Error: Failed to load config file '{s}': {}\n", .{ config_path, err });
            return err;
        };
        config_source = config_path;
        std.debug.print("Loaded configuration from {s}\n", .{config_source});
    } else {
        // Try default config files
        if (config.loadConfig(allocator, "zhttpd.yaml")) |c| {
            cfg = c;
            config_source = "zhttpd.yaml";
            std.debug.print("Loaded configuration from {s}\n", .{config_source});
        } else |_| {
            if (config.loadConfig(allocator, "config.json")) |c| {
                cfg = c;
                config_source = "config.json";
                std.debug.print("Loaded configuration from {s}\n", .{config_source});
            } else |_| {
                cfg = try config.getDefaultConfig(allocator);
                std.debug.print("Using default configuration\n", .{});
            }
        }
    }

    // Apply CLI overrides
    if (options.host) |host| {
        allocator.free(cfg.host);
        cfg.host = try allocator.dupe(u8, host);
    }
    if (options.port) |port| {
        cfg.port = port;
    }
    if (options.static_dir) |dir| {
        allocator.free(cfg.static_dir);
        cfg.static_dir = try allocator.dupe(u8, dir);
    }
    if (options.lua_scripts_dir) |dir| {
        allocator.free(cfg.lua_scripts_dir);
        cfg.lua_scripts_dir = try allocator.dupe(u8, dir);
    }
    if (options.log_level) |level| {
        allocator.free(cfg.log_level);
        cfg.log_level = try allocator.dupe(u8, level);
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
        \\    -c, --config <FILE>        Specify configuration file path
        \\                               (default: zhttpd.yaml, then config.json)
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
        \\    1. File specified with --config
        \\    2. zhttpd.yaml in current directory
        \\    3. config.json in current directory
        \\    4. Built-in defaults
        \\
        \\    Command-line options override configuration file settings.
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
    std.debug.print("Built with Zig\n", .{});
    std.debug.print("https://github.com/zhaozg/zhttpd\n", .{});
}

// Tests
test "parseArgs help flag" {
    // Note: Can't easily test args parsing directly without mocking
    // Just verify the module compiles and functions exist
    const testing = std.testing;
    _ = testing;
}

test "printHelp compiles" {
    // Just verify it compiles - don't actually print during tests
    _ = printHelp;
}

test "printVersion compiles" {
    // Just verify it compiles - don't actually print during tests
    _ = printVersion;
}

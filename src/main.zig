const std = @import("std");
const config = @import("config/config.zig");
const httpz_handlers = @import("handlers/httpz_handlers.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration - try YAML first, then JSON, finally defaults
    const cfg = blk: {
        // Try zhttpd.yaml
        if (config.loadConfig(allocator, "zhttpd.yaml")) |c| {
            std.debug.print("Loaded configuration from zhttpd.yaml\n", .{});
            break :blk c;
        } else |_| {
            // Try config.json
            if (config.loadConfig(allocator, "config.json")) |c| {
                std.debug.print("Loaded configuration from config.json\n", .{});
                break :blk c;
            } else |_| {
                std.debug.print("Using default configuration\n", .{});
                break :blk try config.loadConfig(allocator, "nonexistent.yaml");
            }
        }
    };
    defer cfg.deinit();

    std.debug.print("Starting zhttpd v0.1.0 on {s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("Static files: {s}\n", .{cfg.static_dir});
    std.debug.print("Security headers: {s}\n", .{if (cfg.security_headers) "enabled" else "disabled"});
    std.debug.print("Thread pool size: {d}\n", .{cfg.thread_pool_size});

    // Initialize the HTTP server with httpz
    var server = try httpz_handlers.HttpzServer.init(allocator, cfg);
    defer server.deinit();

    // Setup routes
    try server.setupRoutes();

    // Start the server (blocking)
    try server.listen();
}

test "main module" {
    const testing = std.testing;
    _ = testing;
}

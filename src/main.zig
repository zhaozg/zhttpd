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
                break :blk try config.getDefaultConfig(allocator);
            }
        }
    };
    defer cfg.deinit();

    // Initialize the HTTP server with httpz
    var server = try httpz_handlers.HttpzServer.init(allocator, cfg);
    defer server.deinit();

    // Log startup information using the integrated logger
    server.context.logger.info("Starting zhttpd v0.1.0 on {s}:{d}", .{ cfg.host, cfg.port });
    server.context.logger.info("Static files: {s}", .{cfg.static_dir});
    server.context.logger.info("Security headers: {s}", .{if (cfg.security_headers) "enabled" else "disabled"});
    server.context.logger.info("Thread pool size: {d}", .{cfg.thread_pool_size});

    // Setup routes
    try server.setupRoutes();

    // Start the server (blocking)
    try server.listen();
}

test "main module" {
    const testing = std.testing;
    _ = testing;
}

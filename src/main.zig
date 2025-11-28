const std = @import("std");
const cli = @import("cli.zig");
const httpz_handlers = @import("handlers/httpz_handlers.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments and load configuration
    const result = try cli.parseArgs(allocator);
    const cfg = switch (result) {
        .exit => |code| {
            std.process.exit(code);
        },
        .run => |c| c,
    };
    defer cfg.deinit();

    // Initialize the HTTP server with httpz
    var server = try httpz_handlers.HttpzServer.init(allocator, cfg);
    defer server.deinit();

    // Log startup information using the integrated logger
    server.context.logger.info("Starting zhttpd v{s} on {s}:{d}", .{ cli.VERSION, cfg.host, cfg.port });
    server.context.logger.info("Static files: {s}", .{cfg.static_dir});
    server.context.logger.info("Security headers: {s}", .{if (cfg.security_headers) "enabled" else "disabled"});
    server.context.logger.info("Thread pool size: {d}", .{cfg.thread_pool_size});
    server.context.logger.info("Max connections: {d}", .{cfg.max_connections});
    server.context.logger.info("Request buffer size: {d} bytes", .{cfg.request_buffer_size});
    server.context.logger.info("ETag caching: {s}", .{if (cfg.enable_etag) "enabled" else "disabled"});

    // Setup routes
    try server.setupRoutes();

    // Start the server (blocking)
    try server.listen();
}

test "main module" {
    const testing = std.testing;
    _ = testing;
}

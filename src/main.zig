const std = @import("std");
const config = @import("config/config.zig");
const handlers = @import("handlers/handlers.zig");
const security = @import("security/security.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const cfg = try config.loadConfig(allocator, "config.json");
    defer cfg.deinit();

    std.debug.print("Starting zhttpd v0.1.0 on {s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("Static files: {s}\n", .{cfg.static_dir});
    std.debug.print("Security headers: {s}\n", .{if (cfg.security_headers) "enabled" else "disabled"});

    // Initialize the HTTP server
    var server = try handlers.Server.init(allocator, cfg);
    defer server.deinit();

    // Start the server
    try server.start();
}

test "main module" {
    const testing = std.testing;
    _ = testing;
}

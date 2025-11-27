// zhttpd Health Check module
// Provides health check endpoint with detailed status information
//
// Supports multiple response formats:
// - Simple: Just returns "OK" for basic health checks
// - Detailed: Returns JSON with component status

const std = @import("std");

/// Health status for a component
pub const ComponentStatus = enum {
    healthy,
    degraded,
    unhealthy,

    pub fn toString(self: ComponentStatus) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }
};

/// Overall health check result
pub const HealthCheck = struct {
    status: ComponentStatus = .healthy,
    uptime_seconds: i64 = 0,
    version: []const u8 = "0.1.2",

    // Component statuses
    http_server: ComponentStatus = .healthy,
    lua_engine: ComponentStatus = .healthy,
    graphql_engine: ComponentStatus = .healthy,
    file_cache: ComponentStatus = .healthy,

    /// Compute overall status based on component statuses
    pub fn computeOverallStatus(self: *HealthCheck) void {
        // If any component is unhealthy, overall is unhealthy
        if (self.http_server == .unhealthy or
            self.lua_engine == .unhealthy or
            self.graphql_engine == .unhealthy or
            self.file_cache == .unhealthy)
        {
            self.status = .unhealthy;
            return;
        }

        // If any component is degraded, overall is degraded
        if (self.http_server == .degraded or
            self.lua_engine == .degraded or
            self.graphql_engine == .degraded or
            self.file_cache == .degraded)
        {
            self.status = .degraded;
            return;
        }

        self.status = .healthy;
    }

    /// Generate simple health response ("OK" or "UNHEALTHY")
    pub fn toSimple(self: *const HealthCheck) []const u8 {
        return switch (self.status) {
            .healthy => "OK",
            .degraded => "DEGRADED",
            .unhealthy => "UNHEALTHY",
        };
    }

    /// Generate detailed JSON health response
    pub fn toJson(self: *const HealthCheck, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);

        const writer = buf.writer(allocator);

        try writer.print("{{", .{});
        try writer.print("\"status\":\"{s}\",", .{self.status.toString()});
        try writer.print("\"version\":\"{s}\",", .{self.version});
        try writer.print("\"uptime_seconds\":{d},", .{self.uptime_seconds});
        try writer.print("\"components\":{{", .{});
        try writer.print("\"http_server\":\"{s}\",", .{self.http_server.toString()});
        try writer.print("\"lua_engine\":\"{s}\",", .{self.lua_engine.toString()});
        try writer.print("\"graphql_engine\":\"{s}\",", .{self.graphql_engine.toString()});
        try writer.print("\"file_cache\":\"{s}\"", .{self.file_cache.toString()});
        try writer.print("}}}}", .{});

        return try buf.toOwnedSlice(allocator);
    }

    /// Get HTTP status code based on health
    pub fn httpStatusCode(self: *const HealthCheck) u16 {
        return switch (self.status) {
            .healthy => 200,
            .degraded => 200, // Still return 200 for degraded as service is functional
            .unhealthy => 503, // Service Unavailable
        };
    }
};

/// Create a health check with current server state
pub fn check(start_time: i64, lua_enabled: bool, graphql_enabled: bool) HealthCheck {
    var health = HealthCheck{};

    // Calculate uptime
    health.uptime_seconds = std.time.timestamp() - start_time;

    // Set component statuses based on enabled state
    // Note: In a real implementation, you would check actual component health
    health.http_server = .healthy;
    health.lua_engine = if (lua_enabled) .healthy else .healthy; // Even if disabled, not unhealthy
    health.graphql_engine = if (graphql_enabled) .healthy else .healthy;
    health.file_cache = .healthy;

    health.computeOverallStatus();
    return health;
}

// Tests
test "health check basic" {
    var health = HealthCheck{};
    health.computeOverallStatus();

    try std.testing.expect(health.status == .healthy);
    try std.testing.expectEqualStrings("OK", health.toSimple());
    try std.testing.expect(health.httpStatusCode() == 200);
}

test "health check degraded" {
    var health = HealthCheck{};
    health.lua_engine = .degraded;
    health.computeOverallStatus();

    try std.testing.expect(health.status == .degraded);
    try std.testing.expectEqualStrings("DEGRADED", health.toSimple());
    try std.testing.expect(health.httpStatusCode() == 200);
}

test "health check unhealthy" {
    var health = HealthCheck{};
    health.http_server = .unhealthy;
    health.computeOverallStatus();

    try std.testing.expect(health.status == .unhealthy);
    try std.testing.expectEqualStrings("UNHEALTHY", health.toSimple());
    try std.testing.expect(health.httpStatusCode() == 503);
}

test "health check json format" {
    const allocator = std.testing.allocator;

    var health = HealthCheck{};
    health.uptime_seconds = 3600;
    health.computeOverallStatus();

    const json = try health.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"0.1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uptime_seconds\":3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"components\"") != null);
}

test "health check function" {
    const start_time = std.time.timestamp() - 100; // 100 seconds ago
    const health = check(start_time, true, true);

    try std.testing.expect(health.status == .healthy);
    try std.testing.expect(health.uptime_seconds >= 100);
}

const std = @import("std");

/// Authentication configuration
/// Defines policies for authentication handling
/// Actual JWT/OAuth validation should be delegated to Lua scripts
pub const AuthConfig = struct {
    /// Enable authentication middleware
    enabled: bool = false,
    /// Lua script name for authentication validation
    /// The script should export a `validate` function
    auth_script: []const u8 = "auth",
    /// Paths that require authentication (comma-separated, supports wildcards)
    protected_paths: []const u8 = "/api/*",
    /// Paths that are always public (comma-separated)
    public_paths: []const u8 = "/api/login, /api/register, /api/health",
    /// Header name for token (default: Authorization)
    token_header: []const u8 = "Authorization",
    /// Token prefix to strip (e.g., "Bearer ")
    token_prefix: []const u8 = "Bearer ",
    /// Enable JWT support
    jwt_enabled: bool = true,
    /// Enable OAuth support
    oauth_enabled: bool = false,
};

/// Authentication result from Lua script
pub const AuthResult = struct {
    /// Whether authentication succeeded
    authenticated: bool,
    /// User ID if authenticated
    user_id: ?[]const u8 = null,
    /// User roles/permissions
    roles: ?[]const u8 = null,
    /// Error message if authentication failed
    error_message: ?[]const u8 = null,
    /// Token expiration timestamp (Unix epoch)
    expires_at: ?i64 = null,
};

/// Authentication middleware
/// Delegates actual token validation to Lua scripts for flexibility
pub const AuthMiddleware = struct {
    config: AuthConfig,

    /// Initialize authentication middleware
    pub fn init(config: AuthConfig) AuthMiddleware {
        return AuthMiddleware{
            .config = config,
        };
    }

    /// Check if a path requires authentication
    pub fn requiresAuth(self: *const AuthMiddleware, path: []const u8) bool {
        if (!self.config.enabled) {
            return false;
        }

        // Check if path is in public paths
        if (self.isPublicPath(path)) {
            return false;
        }

        // Check if path matches protected patterns
        return self.isProtectedPath(path);
    }

    /// Check if path is in public paths list
    fn isPublicPath(self: *const AuthMiddleware, path: []const u8) bool {
        var it = std.mem.splitSequence(u8, self.config.public_paths, ",");
        while (it.next()) |public| {
            const trimmed = std.mem.trim(u8, public, " \t");
            if (matchPath(trimmed, path)) {
                return true;
            }
        }
        return false;
    }

    /// Check if path matches protected patterns
    fn isProtectedPath(self: *const AuthMiddleware, path: []const u8) bool {
        var it = std.mem.splitSequence(u8, self.config.protected_paths, ",");
        while (it.next()) |protected| {
            const trimmed = std.mem.trim(u8, protected, " \t");
            if (matchPath(trimmed, path)) {
                return true;
            }
        }
        return false;
    }

    /// Extract token from header value
    pub fn extractToken(self: *const AuthMiddleware, header_value: []const u8) ?[]const u8 {
        if (self.config.token_prefix.len > 0) {
            if (std.mem.startsWith(u8, header_value, self.config.token_prefix)) {
                return header_value[self.config.token_prefix.len..];
            }
            return null;
        }
        return header_value;
    }

    /// Build request data for Lua auth script
    /// Format: { "token": "...", "method": "...", "path": "...", "type": "jwt"|"oauth" }
    /// JSON-escapes special characters in token and path to prevent injection
    pub fn buildAuthRequest(self: *const AuthMiddleware, allocator: std.mem.Allocator, token: []const u8, method: []const u8, path: []const u8) ![]const u8 {
        const auth_type: []const u8 = if (self.config.jwt_enabled) "jwt" else if (self.config.oauth_enabled) "oauth" else "unknown";

        // Escape token and path for JSON safety
        const escaped_token = try escapeJsonString(allocator, token);
        defer allocator.free(escaped_token);
        const escaped_path = try escapeJsonString(allocator, path);
        defer allocator.free(escaped_path);

        return try std.fmt.allocPrint(allocator,
            \\{{"token":"{s}","method":"{s}","path":"{s}","type":"{s}"}}
        , .{ escaped_token, method, escaped_path, auth_type });
    }
};

/// Escape a string for safe inclusion in JSON
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 32) {
                    // Escape control characters as \uXXXX
                    var buf: [6]u8 = undefined;
                    const escape_str = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try result.appendSlice(allocator, escape_str);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Simple path matching with wildcard support
fn matchPath(pattern: []const u8, path: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, pattern, path)) {
        return true;
    }

    // Wildcard at end (e.g., /api/*)
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, prefix);
    }

    return false;
}

// Tests
test "auth middleware path matching" {
    const testing = std.testing;

    const middleware = AuthMiddleware.init(.{
        .enabled = true,
        .protected_paths = "/api/*",
        .public_paths = "/api/login, /api/register",
    });

    // Public paths should not require auth
    try testing.expect(middleware.requiresAuth("/api/login") == false);
    try testing.expect(middleware.requiresAuth("/api/register") == false);

    // Protected paths should require auth
    try testing.expect(middleware.requiresAuth("/api/users") == true);
    try testing.expect(middleware.requiresAuth("/api/data") == true);

    // Non-matching paths should not require auth
    try testing.expect(middleware.requiresAuth("/static/file.js") == false);
}

test "auth middleware token extraction" {
    const testing = std.testing;

    const middleware = AuthMiddleware.init(.{
        .enabled = true,
        .token_prefix = "Bearer ",
    });

    const token = middleware.extractToken("Bearer abc123");
    try testing.expect(token != null);
    try testing.expectEqualStrings("abc123", token.?);

    // Invalid prefix
    const invalid = middleware.extractToken("Basic xyz");
    try testing.expect(invalid == null);
}

test "path matching" {
    const testing = std.testing;

    // Exact match
    try testing.expect(matchPath("/api/users", "/api/users") == true);
    try testing.expect(matchPath("/api/users", "/api/other") == false);

    // Wildcard match
    try testing.expect(matchPath("/api/*", "/api/users") == true);
    try testing.expect(matchPath("/api/*", "/api/users/123") == true);
    try testing.expect(matchPath("/api/*", "/other/path") == false);
}

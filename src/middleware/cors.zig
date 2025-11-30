const std = @import("std");

/// CORS (Cross-Origin Resource Sharing) configuration
/// Defines policies for cross-origin requests
pub const CorsConfig = struct {
    /// Allowed origins ("*" for any, or comma-separated list)
    allowed_origins: []const u8 = "*",
    /// Allowed HTTP methods
    allowed_methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS, PATCH",
    /// Allowed request headers
    allowed_headers: []const u8 = "Content-Type, Authorization, X-Requested-With, Accept, Origin",
    /// Headers exposed to the client
    exposed_headers: []const u8 = "Content-Length, Content-Range",
    /// Whether credentials (cookies, auth headers) are allowed
    allow_credentials: bool = false,
    /// Max age for preflight cache in seconds
    max_age: u32 = 86400, // 24 hours
    /// Enable CORS support
    enabled: bool = false,
};

/// CORS middleware handler
pub const CorsMiddleware = struct {
    config: CorsConfig,
    /// Pre-formatted max-age string (optimization: avoids formatting on every preflight request)
    max_age_str: [16]u8 = undefined,
    max_age_len: usize = 0,
    /// Flag indicating if allowed_origins is wildcard (optimization: avoids string comparison per request)
    is_wildcard_origin: bool = false,

    /// Initialize CORS middleware with configuration
    pub fn init(config: CorsConfig) CorsMiddleware {
        var middleware = CorsMiddleware{
            .config = config,
            .is_wildcard_origin = std.mem.eql(u8, config.allowed_origins, "*"),
        };
        // Pre-format max-age string
        if (std.fmt.bufPrint(&middleware.max_age_str, "{d}", .{config.max_age})) |slice| {
            middleware.max_age_len = slice.len;
        } else |_| {
            middleware.max_age_str[0] = '0';
            middleware.max_age_len = 1;
        }
        return middleware;
    }

    /// Get pre-formatted max-age string
    pub fn getMaxAgeStr(self: *const CorsMiddleware) []const u8 {
        return self.max_age_str[0..self.max_age_len];
    }

    /// Check if origin is allowed
    pub fn isOriginAllowed(self: *const CorsMiddleware, origin: []const u8) bool {
        if (self.is_wildcard_origin) {
            return true;
        }

        // Check comma-separated list of origins
        var it = std.mem.splitSequence(u8, self.config.allowed_origins, ",");
        while (it.next()) |allowed| {
            const trimmed = std.mem.trim(u8, allowed, " \t");
            if (std.mem.eql(u8, trimmed, origin)) {
                return true;
            }
        }
        return false;
    }

    /// Get CORS headers for a request
    /// Returns null if origin is not allowed
    pub fn getHeaders(self: *const CorsMiddleware, origin: []const u8) ?CorsHeaders {
        if (!self.config.enabled) {
            return null;
        }

        if (!self.isOriginAllowed(origin)) {
            return null;
        }

        const allow_origin = if (self.is_wildcard_origin)
            "*"
        else
            origin;

        return CorsHeaders{
            .access_control_allow_origin = allow_origin,
            .access_control_allow_methods = self.config.allowed_methods,
            .access_control_allow_headers = self.config.allowed_headers,
            .access_control_expose_headers = self.config.exposed_headers,
            .access_control_allow_credentials = self.config.allow_credentials,
            .access_control_max_age = self.config.max_age,
        };
    }
};

/// CORS response headers
pub const CorsHeaders = struct {
    access_control_allow_origin: []const u8,
    access_control_allow_methods: []const u8,
    access_control_allow_headers: []const u8,
    access_control_expose_headers: []const u8,
    access_control_allow_credentials: bool,
    access_control_max_age: u32,
};

// Tests
test "cors middleware wildcard" {
    const testing = std.testing;

    const middleware = CorsMiddleware.init(.{
        .enabled = true,
        .allowed_origins = "*",
    });

    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://another.com") == true);

    const headers = middleware.getHeaders("https://example.com");
    try testing.expect(headers != null);
    try testing.expectEqualStrings("*", headers.?.access_control_allow_origin);
}

test "cors middleware specific origins" {
    const testing = std.testing;

    const middleware = CorsMiddleware.init(.{
        .enabled = true,
        .allowed_origins = "https://example.com, https://trusted.com",
    });

    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://trusted.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://untrusted.com") == false);

    const headers = middleware.getHeaders("https://example.com");
    try testing.expect(headers != null);
    try testing.expectEqualStrings("https://example.com", headers.?.access_control_allow_origin);
}

test "cors middleware disabled" {
    const testing = std.testing;

    const middleware = CorsMiddleware.init(.{
        .enabled = false,
    });

    const headers = middleware.getHeaders("https://example.com");
    try testing.expect(headers == null);
}

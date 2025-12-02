const std = @import("std");
const LruCache = @import("../cache/lru_cache.zig").LruCache;

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
    /// LRU cache size for origin decisions (0 to disable caching)
    /// Recommended: 1000 for production (caches allowed/denied decisions)
    origin_cache_size: usize = 1000,
};

/// CORS middleware handler
///
/// Optimization: Uses LRU cache to avoid repeated origin checks for the same origins.
/// This is beneficial when serving many requests from the same set of origins.
/// Cache stores boolean decisions (allowed/not allowed) for up to 1000 origins by default.
pub const CorsMiddleware = struct {
    config: CorsConfig,
    /// Pre-formatted max-age string (optimization: avoids formatting on every preflight request)
    max_age_str: [16]u8 = undefined,
    max_age_len: usize = 0,
    /// Flag indicating if allowed_origins is wildcard (optimization: avoids string comparison per request)
    is_wildcard_origin: bool = false,
    /// LRU cache for origin decisions (optimization for repeated origins)
    origin_cache: ?LruCache([]const u8, bool, void) = null,
    allocator: ?std.mem.Allocator = null,

    /// Initialize CORS middleware with configuration
    pub fn init(allocator: std.mem.Allocator, config: CorsConfig) !CorsMiddleware {
        var middleware = CorsMiddleware{
            .config = config,
            .is_wildcard_origin = std.mem.eql(u8, config.allowed_origins, "*"),
            .allocator = allocator,
        };

        // Pre-format max-age string
        if (std.fmt.bufPrint(&middleware.max_age_str, "{d}", .{config.max_age})) |slice| {
            middleware.max_age_len = slice.len;
        } else |_| {
            middleware.max_age_str[0] = '0';
            middleware.max_age_len = 1;
        }

        // Initialize origin cache if size > 0 and not wildcard
        // (wildcard origins don't need caching as they always allow)
        if (config.origin_cache_size > 0 and !middleware.is_wildcard_origin) {
            const cache_config = @import("../cache/lru_cache.zig").CacheConfig{
                .max_size = config.origin_cache_size,
                .default_ttl_ms = 0, // No expiration
            };
            middleware.origin_cache = LruCache([]const u8, bool, void).init(
                allocator,
                cache_config,
                {},
                null,
            );
        }

        return middleware;
    }

    /// Clean up resources
    pub fn deinit(self: *CorsMiddleware) void {
        if (self.origin_cache) |*cache| {
            cache.deinit();
        }
    }

    /// Get pre-formatted max-age string
    pub fn getMaxAgeStr(self: *const CorsMiddleware) []const u8 {
        return self.max_age_str[0..self.max_age_len];
    }

    /// Check if origin is allowed
    /// Optimized with LRU cache to avoid repeated string comparisons for the same origins
    pub fn isOriginAllowed(self: *CorsMiddleware, origin: []const u8) bool {
        if (self.is_wildcard_origin) {
            return true;
        }

        // Try cache first if enabled
        if (self.origin_cache) |*cache| {
            if (cache.getPtr(origin)) |result| {
                defer result.entry.release();
                return result.value.*;
            }
        }

        // Check comma-separated list of origins
        var it = std.mem.splitSequence(u8, self.config.allowed_origins, ",");
        var allowed = false;
        while (it.next()) |allowed_origin| {
            const trimmed = std.mem.trim(u8, allowed_origin, " \t");
            if (std.mem.eql(u8, trimmed, origin)) {
                allowed = true;
                break;
            }
        }

        // Cache the decision
        if (self.origin_cache) |*cache| {
            cache.put(origin, allowed) catch {};
        }

        return allowed;
    }

    /// Get cache statistics for monitoring (returns null if caching is disabled)
    pub fn getCacheStats(self: *CorsMiddleware) ?struct { size: usize, max_size: usize } {
        if (self.origin_cache) |*cache| {
            return .{
                .size = cache.getCount(),
                .max_size = self.config.origin_cache_size,
            };
        }
        return null;
    }

    /// Clear the origin cache (useful when configuration changes)
    pub fn clearCache(self: *CorsMiddleware) void {
        if (self.origin_cache) |*cache| {
            cache.clear();
        }
    }

    /// Get CORS headers for a request
    /// Returns null if origin is not allowed
    pub fn getHeaders(self: *CorsMiddleware, origin: []const u8) ?CorsHeaders {
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
    const allocator = testing.allocator;

    var middleware = try CorsMiddleware.init(allocator, .{
        .enabled = true,
        .allowed_origins = "*",
    });
    defer middleware.deinit();

    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://another.com") == true);

    const headers = middleware.getHeaders("https://example.com");
    try testing.expect(headers != null);
    try testing.expectEqualStrings("*", headers.?.access_control_allow_origin);
}

test "cors middleware specific origins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var middleware = try CorsMiddleware.init(allocator, .{
        .enabled = true,
        .allowed_origins = "https://example.com, https://trusted.com",
    });
    defer middleware.deinit();

    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://trusted.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://untrusted.com") == false);

    const headers = middleware.getHeaders("https://example.com");
    try testing.expect(headers != null);
    try testing.expectEqualStrings("https://example.com", headers.?.access_control_allow_origin);
}

test "cors middleware disabled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var middleware = try CorsMiddleware.init(allocator, .{
        .enabled = false,
    });
    defer middleware.deinit();

    const headers = middleware.getHeaders("https://example.com");
    try testing.expect(headers == null);
}

test "cors middleware origin caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var middleware = try CorsMiddleware.init(allocator, .{
        .enabled = true,
        .allowed_origins = "https://example.com, https://trusted.com",
        .origin_cache_size = 10,
    });
    defer middleware.deinit();

    // First check - should cache
    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://untrusted.com") == false);

    // Second check - should hit cache
    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.isOriginAllowed("https://untrusted.com") == false);

    // Verify cache stats
    if (middleware.getCacheStats()) |stats| {
        try testing.expect(stats.size == 2); // Two origins cached
        try testing.expect(stats.max_size == 10);
    } else {
        try testing.expect(false); // Cache should be enabled
    }

    // Test cache clear
    middleware.clearCache();
    if (middleware.getCacheStats()) |stats| {
        try testing.expect(stats.size == 0); // Cache cleared
    }
}

test "cors middleware no caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var middleware = try CorsMiddleware.init(allocator, .{
        .enabled = true,
        .allowed_origins = "https://example.com",
        .origin_cache_size = 0, // Disable caching
    });
    defer middleware.deinit();

    try testing.expect(middleware.isOriginAllowed("https://example.com") == true);
    try testing.expect(middleware.getCacheStats() == null); // No cache
}

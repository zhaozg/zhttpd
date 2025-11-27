const std = @import("std");

/// Security header definitions for HTTP responses
pub const SecurityHeaders = struct {
    /// Content Security Policy
    csp: []const u8 = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';",
    /// X-Frame-Options
    x_frame_options: []const u8 = "SAMEORIGIN",
    /// X-Content-Type-Options
    x_content_type_options: []const u8 = "nosniff",
    /// X-XSS-Protection
    x_xss_protection: []const u8 = "1; mode=block",
    /// Strict-Transport-Security
    hsts: []const u8 = "max-age=31536000; includeSubDomains",
    /// Referrer-Policy
    referrer_policy: []const u8 = "strict-origin-when-cross-origin",
    /// Permissions-Policy
    permissions_policy: []const u8 = "geolocation=(), microphone=(), camera=()",
};

pub const default_headers = SecurityHeaders{};

/// Apply security headers to response
pub fn applyHeaders(response: anytype, headers: SecurityHeaders) void {
    _ = response;
    _ = headers;
    // This will be implemented with the actual HTTP library
    // response.header("Content-Security-Policy", headers.csp);
    // response.header("X-Frame-Options", headers.x_frame_options);
    // response.header("X-Content-Type-Options", headers.x_content_type_options);
    // response.header("X-XSS-Protection", headers.x_xss_protection);
    // response.header("Strict-Transport-Security", headers.hsts);
    // response.header("Referrer-Policy", headers.referrer_policy);
    // response.header("Permissions-Policy", headers.permissions_policy);
}

// ============================================================================
// Content Security Policy (CSP) Generator
// ============================================================================

/// CSP Directive values
pub const CspDirective = struct {
    /// Sources allowed (e.g., "'self'", "'unsafe-inline'", "https://example.com")
    sources: []const []const u8 = &[_][]const u8{"'self'"},

    /// Format directive to string
    pub fn format(self: CspDirective, allocator: std.mem.Allocator) ![]const u8 {
        if (self.sources.len == 0) {
            return try allocator.dupe(u8, "'none'");
        }

        var total_len: usize = 0;
        for (self.sources, 0..) |source, i| {
            total_len += source.len;
            if (i < self.sources.len - 1) {
                total_len += 1; // space separator
            }
        }

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.sources, 0..) |source, i| {
            @memcpy(result[pos..][0..source.len], source);
            pos += source.len;
            if (i < self.sources.len - 1) {
                result[pos] = ' ';
                pos += 1;
            }
        }
        return result;
    }
};

/// Content Security Policy generator configuration
pub const CspConfig = struct {
    /// default-src directive
    default_src: CspDirective = .{},
    /// script-src directive
    script_src: ?CspDirective = null,
    /// style-src directive
    style_src: ?CspDirective = null,
    /// img-src directive
    img_src: ?CspDirective = null,
    /// font-src directive
    font_src: ?CspDirective = null,
    /// connect-src directive (for XHR, WebSocket, etc.)
    connect_src: ?CspDirective = null,
    /// frame-src directive
    frame_src: ?CspDirective = null,
    /// object-src directive
    object_src: ?CspDirective = null,
    /// media-src directive
    media_src: ?CspDirective = null,
    /// worker-src directive
    worker_src: ?CspDirective = null,
    /// frame-ancestors directive (replaces X-Frame-Options)
    frame_ancestors: ?CspDirective = null,
    /// form-action directive
    form_action: ?CspDirective = null,
    /// base-uri directive
    base_uri: ?CspDirective = null,
    /// upgrade-insecure-requests directive
    upgrade_insecure_requests: bool = false,
    /// block-all-mixed-content directive
    block_all_mixed_content: bool = false,
    /// report-uri for CSP violation reports
    report_uri: ?[]const u8 = null,
    /// report-to for CSP violation reports (newer)
    report_to: ?[]const u8 = null,
};

/// CSP Generator for creating Content Security Policy headers
pub const CspGenerator = struct {
    config: CspConfig,

    pub fn init(config: CspConfig) CspGenerator {
        return CspGenerator{ .config = config };
    }

    /// Generate a complete CSP header value
    pub fn generate(self: *const CspGenerator, allocator: std.mem.Allocator) ![]const u8 {
        var parts = std.ArrayList([]const u8).init(allocator);
        defer {
            for (parts.items) |item| {
                allocator.free(item);
            }
            parts.deinit();
        }

        // default-src
        const default_src_value = try self.config.default_src.format(allocator);
        const default_src = try std.fmt.allocPrint(allocator, "default-src {s}", .{default_src_value});
        allocator.free(default_src_value);
        try parts.append(default_src);

        // script-src
        if (self.config.script_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "script-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // style-src
        if (self.config.style_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "style-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // img-src
        if (self.config.img_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "img-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // font-src
        if (self.config.font_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "font-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // connect-src
        if (self.config.connect_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "connect-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // frame-src
        if (self.config.frame_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "frame-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // object-src
        if (self.config.object_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "object-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // media-src
        if (self.config.media_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "media-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // worker-src
        if (self.config.worker_src) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "worker-src {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // frame-ancestors
        if (self.config.frame_ancestors) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "frame-ancestors {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // form-action
        if (self.config.form_action) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "form-action {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // base-uri
        if (self.config.base_uri) |directive| {
            const value = try directive.format(allocator);
            const part = try std.fmt.allocPrint(allocator, "base-uri {s}", .{value});
            allocator.free(value);
            try parts.append(part);
        }

        // upgrade-insecure-requests
        if (self.config.upgrade_insecure_requests) {
            try parts.append(try allocator.dupe(u8, "upgrade-insecure-requests"));
        }

        // block-all-mixed-content
        if (self.config.block_all_mixed_content) {
            try parts.append(try allocator.dupe(u8, "block-all-mixed-content"));
        }

        // report-uri
        if (self.config.report_uri) |uri| {
            const part = try std.fmt.allocPrint(allocator, "report-uri {s}", .{uri});
            try parts.append(part);
        }

        // report-to
        if (self.config.report_to) |group| {
            const part = try std.fmt.allocPrint(allocator, "report-to {s}", .{group});
            try parts.append(part);
        }

        // Join all parts with "; "
        var total_len: usize = 0;
        for (parts.items, 0..) |part, i| {
            total_len += part.len;
            if (i < parts.items.len - 1) {
                total_len += 2; // "; "
            }
        }

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (parts.items, 0..) |part, i| {
            @memcpy(result[pos..][0..part.len], part);
            pos += part.len;
            if (i < parts.items.len - 1) {
                result[pos] = ';';
                result[pos + 1] = ' ';
                pos += 2;
            }
        }

        return result;
    }

    /// Generate a strict CSP for API endpoints (minimal permissions)
    pub fn generateApiCsp(allocator: std.mem.Allocator) ![]const u8 {
        const none_sources = [_][]const u8{"'none'"};
        const generator = CspGenerator.init(.{
            .default_src = .{ .sources = &none_sources },
            .frame_ancestors = .{ .sources = &none_sources },
        });
        return generator.generate(allocator);
    }

    /// Generate a standard CSP for web pages
    pub fn generateWebCsp(allocator: std.mem.Allocator) ![]const u8 {
        const self_sources = [_][]const u8{"'self'"};
        const self_inline_sources = [_][]const u8{ "'self'", "'unsafe-inline'" };
        const img_sources = [_][]const u8{ "'self'", "data:", "https:" };
        const generator = CspGenerator.init(.{
            .default_src = .{ .sources = &self_sources },
            .script_src = .{ .sources = &self_inline_sources },
            .style_src = .{ .sources = &self_inline_sources },
            .img_src = .{ .sources = &img_sources },
            .frame_ancestors = .{ .sources = &self_sources },
            .upgrade_insecure_requests = true,
        });
        return generator.generate(allocator);
    }
};

// ============================================================================
// TLS Configuration (for documentation and reverse proxy setup)
// ============================================================================

/// TLS configuration structure for documentation purposes
/// Note: httpz does not have native TLS support. TLS should be terminated
/// at a reverse proxy (nginx, Caddy, haproxy) or load balancer.
pub const TlsConfig = struct {
    /// Enable TLS (requires reverse proxy)
    enabled: bool = false,
    /// Certificate file path (for reverse proxy configuration reference)
    cert_file: ?[]const u8 = null,
    /// Private key file path (for reverse proxy configuration reference)
    key_file: ?[]const u8 = null,
    /// Minimum TLS version (recommended: TLS 1.2 or 1.3)
    min_version: TlsVersion = .tls_1_2,
    /// Enable HSTS header
    hsts_enabled: bool = true,
    /// HSTS max-age in seconds (default: 1 year)
    hsts_max_age: u32 = 31536000,
    /// HSTS include subdomains
    hsts_include_subdomains: bool = true,
    /// HSTS preload (for browser preload lists)
    hsts_preload: bool = false,
    /// Enable OCSP stapling (reverse proxy setting)
    ocsp_stapling: bool = true,
    /// Preferred cipher suites (reference for reverse proxy)
    preferred_ciphers: []const u8 = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384",
};

pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

/// Generate nginx TLS configuration snippet
pub fn generateNginxTlsConfig(allocator: std.mem.Allocator, config: TlsConfig) ![]const u8 {
    const hsts_header = if (config.hsts_enabled) blk: {
        const preload_str = if (config.hsts_preload) "; preload" else "";
        const subdomains_str = if (config.hsts_include_subdomains) "; includeSubDomains" else "";
        break :blk try std.fmt.allocPrint(allocator, "add_header Strict-Transport-Security \"max-age={d}{s}{s}\" always;", .{ config.hsts_max_age, subdomains_str, preload_str });
    } else try allocator.dupe(u8, "# HSTS disabled");
    defer allocator.free(hsts_header);

    const min_version_str = switch (config.min_version) {
        .tls_1_2 => "TLSv1.2 TLSv1.3",
        .tls_1_3 => "TLSv1.3",
    };

    const ocsp_str = if (config.ocsp_stapling) "ssl_stapling on;\n    ssl_stapling_verify on;" else "# OCSP stapling disabled";

    return try std.fmt.allocPrint(allocator,
        \\# TLS Configuration for nginx
        \\# Place this in your nginx server block
        \\
        \\ssl_certificate {s};
        \\ssl_certificate_key {s};
        \\ssl_protocols {s};
        \\ssl_ciphers {s};
        \\ssl_prefer_server_ciphers on;
        \\ssl_session_cache shared:SSL:10m;
        \\ssl_session_timeout 10m;
        \\{s}
        \\{s}
    , .{
        config.cert_file orelse "/path/to/cert.pem",
        config.key_file orelse "/path/to/key.pem",
        min_version_str,
        config.preferred_ciphers,
        ocsp_str,
        hsts_header,
    });
}

// ============================================================================
// Route-based Request Size Limits
// ============================================================================

/// Route-specific size limit configuration
pub const RouteSizeLimit = struct {
    /// Path pattern (supports wildcards like /api/*)
    path_pattern: []const u8,
    /// Maximum body size in bytes for this route
    max_body_size: usize,
};

/// Route size limit manager
pub const RouteSizeLimiter = struct {
    limits: []const RouteSizeLimit,
    default_limit: usize,

    pub fn init(limits: []const RouteSizeLimit, default_limit: usize) RouteSizeLimiter {
        return RouteSizeLimiter{
            .limits = limits,
            .default_limit = default_limit,
        };
    }

    /// Get the maximum body size for a given path
    pub fn getMaxBodySize(self: *const RouteSizeLimiter, path: []const u8) usize {
        for (self.limits) |limit| {
            if (matchPath(limit.path_pattern, path)) {
                return limit.max_body_size;
            }
        }
        return self.default_limit;
    }

    /// Check if body size is within limit for a given path
    pub fn isWithinLimit(self: *const RouteSizeLimiter, path: []const u8, body_size: usize) bool {
        return body_size <= self.getMaxBodySize(path);
    }
};

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

// ============================================================================
// Tests
// ============================================================================

test "security headers" {
    const headers = default_headers;
    try std.testing.expect(headers.x_frame_options.len > 0);
    try std.testing.expect(headers.csp.len > 0);
}

test "csp directive format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sources = [_][]const u8{ "'self'", "'unsafe-inline'" };
    const directive = CspDirective{ .sources = &sources };
    const result = try directive.format(allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("'self' 'unsafe-inline'", result);
}

test "csp generator basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const self_sources = [_][]const u8{"'self'"};
    const generator = CspGenerator.init(.{
        .default_src = .{ .sources = &self_sources },
    });
    const csp = try generator.generate(allocator);
    defer allocator.free(csp);

    try testing.expectEqualStrings("default-src 'self'", csp);
}

test "csp generator with multiple directives" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const self_sources = [_][]const u8{"'self'"};
    const inline_sources = [_][]const u8{ "'self'", "'unsafe-inline'" };
    const generator = CspGenerator.init(.{
        .default_src = .{ .sources = &self_sources },
        .script_src = .{ .sources = &inline_sources },
        .upgrade_insecure_requests = true,
    });
    const csp = try generator.generate(allocator);
    defer allocator.free(csp);

    try testing.expect(std.mem.indexOf(u8, csp, "default-src 'self'") != null);
    try testing.expect(std.mem.indexOf(u8, csp, "script-src 'self' 'unsafe-inline'") != null);
    try testing.expect(std.mem.indexOf(u8, csp, "upgrade-insecure-requests") != null);
}

test "csp generator api preset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const csp = try CspGenerator.generateApiCsp(allocator);
    defer allocator.free(csp);

    try testing.expect(std.mem.indexOf(u8, csp, "default-src 'none'") != null);
}

test "csp generator web preset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const csp = try CspGenerator.generateWebCsp(allocator);
    defer allocator.free(csp);

    try testing.expect(std.mem.indexOf(u8, csp, "default-src 'self'") != null);
    try testing.expect(std.mem.indexOf(u8, csp, "upgrade-insecure-requests") != null);
}

test "route size limiter" {
    const testing = std.testing;

    const limits = [_]RouteSizeLimit{
        .{ .path_pattern = "/api/upload", .max_body_size = 50 * 1024 * 1024 }, // 50MB
        .{ .path_pattern = "/api/*", .max_body_size = 1 * 1024 * 1024 }, // 1MB
        .{ .path_pattern = "/graphql", .max_body_size = 100 * 1024 }, // 100KB
    };

    const limiter = RouteSizeLimiter.init(&limits, 10 * 1024 * 1024); // 10MB default

    // Specific route match
    try testing.expect(limiter.getMaxBodySize("/api/upload") == 50 * 1024 * 1024);

    // Wildcard match
    try testing.expect(limiter.getMaxBodySize("/api/users") == 1 * 1024 * 1024);

    // Exact match
    try testing.expect(limiter.getMaxBodySize("/graphql") == 100 * 1024);

    // Default (no match)
    try testing.expect(limiter.getMaxBodySize("/other/path") == 10 * 1024 * 1024);

    // Size check
    try testing.expect(limiter.isWithinLimit("/graphql", 50 * 1024) == true);
    try testing.expect(limiter.isWithinLimit("/graphql", 200 * 1024) == false);
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

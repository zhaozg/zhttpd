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

test "security headers" {
    const headers = default_headers;
    try std.testing.expect(headers.x_frame_options.len > 0);
    try std.testing.expect(headers.csp.len > 0);
}

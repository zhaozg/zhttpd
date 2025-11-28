//! Static File Handler
//!
//! Serves static files from the configured static directory.
//! Supports ETag caching, content type detection, and security headers.

const std = @import("std");
const httpz = @import("httpz");
const security = @import("../security/security.zig");
const FileCache = @import("../cache/file_cache.zig").FileCache;
const handler = @import("handler.zig");

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB max file size

/// Serve static files from the configured directory
pub fn handle(ctx_ptr: *anyopaque, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = @as(*@import("httpz_handlers.zig").AppContext, @ptrCast(@alignCast(ctx_ptr)));

    const path = req.url.path;

    // Normalize path
    const clean_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;

    // Security: Prevent path traversal attacks
    if (std.mem.indexOf(u8, clean_path, "..") != null) {
        res.status = 400;
        res.body = "Bad Request";
        return;
    }

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ ctx.config.static_dir, clean_path });

    // Try to open the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        res.status = 404;
        res.body = "File Not Found";
        return;
    };
    defer file.close();

    // Get file size and modification time
    const stat = try file.stat();
    const file_size = stat.size;
    const file_mtime = stat.mtime;

    if (file_size > MAX_FILE_SIZE) {
        res.status = 413;
        res.body = "File too large";
        return;
    }

    // Generate ETag if enabled
    if (ctx.config.enable_etag) {
        const etag = try FileCache.generateETag(res.arena, file_size, file_mtime);

        // Check If-None-Match header for conditional requests
        if (req.headers.get("if-none-match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, etag)) {
                // File hasn't changed, return 304 Not Modified
                res.status = 304;
                res.headers.add("ETag", etag);
                res.body = "";
                return;
            }
        }

        // Add ETag header to response
        res.headers.add("ETag", etag);
        // Add Cache-Control header for better caching
        res.headers.add("Cache-Control", "public, max-age=3600");
    }

    // Use the response arena allocator directly - more efficient
    const content = try res.arena.alloc(u8, file_size);
    const bytes_read = try file.readAll(content);

    // Set content type
    res.content_type = getContentType(file_path);

    // Add security headers if enabled
    if (ctx.config.security_headers) {
        addSecurityHeaders(res);
    }

    // Set response body
    res.body = content[0..bytes_read];
}

/// Get content type for a file path using httpz's built-in MIME type detection
/// Falls back to BINARY for unknown extensions
fn getContentType(path: []const u8) httpz.ContentType {
    const content_type = httpz.ContentType.forFile(path);
    // httpz returns UNKNOWN for unrecognized extensions, use BINARY instead
    return if (content_type == .UNKNOWN) .BINARY else content_type;
}

fn addSecurityHeaders(res: *httpz.Response) void {
    const headers = security.default_headers;

    res.headers.add("Content-Security-Policy", headers.csp);
    res.headers.add("X-Frame-Options", headers.x_frame_options);
    res.headers.add("X-Content-Type-Options", headers.x_content_type_options);
    res.headers.add("X-XSS-Protection", headers.x_xss_protection);
    res.headers.add("Strict-Transport-Security", headers.hsts);
    res.headers.add("Referrer-Policy", headers.referrer_policy);
    res.headers.add("Permissions-Policy", headers.permissions_policy);
}

// Tests
test "getContentType returns correct MIME types" {
    const testing = std.testing;

    // Test common web file types
    try testing.expect(getContentType("/static/index.html") == httpz.ContentType.HTML);
    try testing.expect(getContentType("/style.css") == httpz.ContentType.CSS);
    try testing.expect(getContentType("/app.js") == httpz.ContentType.JS);
    try testing.expect(getContentType("/data.json") == httpz.ContentType.JSON);
    try testing.expect(getContentType("/logo.png") == httpz.ContentType.PNG);
    try testing.expect(getContentType("/photo.jpg") == httpz.ContentType.JPG);
    try testing.expect(getContentType("/photo.jpeg") == httpz.ContentType.JPG);
    try testing.expect(getContentType("/image.gif") == httpz.ContentType.GIF);
    try testing.expect(getContentType("/icon.svg") == httpz.ContentType.SVG);
    try testing.expect(getContentType("/favicon.ico") == httpz.ContentType.ICO);

    // Test that unknown extensions return BINARY
    try testing.expect(getContentType("/unknown.xyz") == httpz.ContentType.BINARY);
    try testing.expect(getContentType("/noextension") == httpz.ContentType.BINARY);
}

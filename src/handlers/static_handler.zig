//! Static File Handler
//!
//! Serves static files from the configured static directory.
//! Supports ETag caching, content type detection, and security headers.

const std = @import("std");
const httpz = @import("httpz");
const security = @import("../security/security.zig");
const FileCache = @import("../cache/file_cache.zig").FileCache;
const AppContext = @import("httpz_handlers.zig").AppContext;

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB max file size

/// Serve static files from the configured directory
pub fn handle(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const path = req.url.path;

    // Normalize path
    const clean_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;

    // Security: Prevent path traversal attacks with comprehensive checks
    // Combined security validation for efficiency
    if (!isPathSafe(clean_path)) {
        res.status = 400;
        res.body = "Bad Request";
        return;
    }

    // Get the absolute path of static directory (use cached value if available)
    const static_dir_abs = ctx.static_dir_abs orelse blk: {
        // Fallback: compute the path if not cached (should rarely happen)
        break :blk std.fs.cwd().realpathAlloc(res.arena, ctx.config.static_dir) catch {
            res.status = 500;
            res.body = "Internal Server Error";
            return;
        };
    };

    // Build the target file path (strip leading slash from clean_path)
    const rel_path = if (clean_path.len > 0 and clean_path[0] == '/') clean_path[1..] else clean_path;
    const joined_path = std.fs.path.join(res.arena, &[_][]const u8{ static_dir_abs, rel_path }) catch {
        res.status = 500;
        res.body = "Internal Server Error";
        return;
    };

    // Resolve the full path and verify it stays within static_dir
    const target_abs = std.fs.cwd().realpathAlloc(res.arena, joined_path) catch {
        // File doesn't exist or can't be resolved
        res.status = 404;
        res.body = "File Not Found";
        return;
    };

    // Verify the resolved path is within static_dir (prevent traversal via symlinks)
    if (!std.mem.startsWith(u8, target_abs, static_dir_abs)) {
        res.status = 400;
        res.body = "Bad Request";
        return;
    }

    // Additional check: ensure there's a path separator after static_dir (or exact match)
    if (target_abs.len > static_dir_abs.len and target_abs[static_dir_abs.len] != std.fs.path.sep) {
        res.status = 400;
        res.body = "Bad Request";
        return;
    }

    // Try to open the file using the verified absolute path
    const file = std.fs.cwd().openFile(target_abs, .{}) catch {
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
    res.content_type = getContentType(target_abs);

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

/// Combined path security validation (single pass optimization)
/// Checks for:
/// - ".." sequences (path traversal)
/// - URL-encoded path traversal attempts (%2e, %2f, %5c)
/// - Backslash (Windows-style path separator)
/// - Null bytes
fn isPathSafe(path: []const u8) bool {
    var i: usize = 0;
    var prev_char: u8 = 0;

    while (i < path.len) : (i += 1) {
        const c = path[i];

        // Check for null bytes
        if (c == 0) return false;

        // Check for backslash
        if (c == '\\') return false;

        // Check for ".." sequence
        if (c == '.' and prev_char == '.') return false;

        // Check for URL-encoded characters
        if (c == '%' and i + 2 < path.len) {
            const hex = path[i + 1 .. i + 3];
            // Check for encoded '.' (%2e or %2E)
            if (std.ascii.eqlIgnoreCase(hex, "2e")) {
                // Look for pattern like %2e%2e or %2e. or .%2e
                if (i + 5 < path.len and path[i + 3] == '%') {
                    const hex2 = path[i + 4 .. i + 6];
                    if (std.ascii.eqlIgnoreCase(hex2, "2e")) {
                        return false; // Found %2e%2e
                    }
                }
                if (i + 3 < path.len and path[i + 3] == '.') {
                    return false; // Found %2e.
                }
                if (prev_char == '.') {
                    return false; // Found .%2e
                }
            }
            // Check for encoded '/' (%2f or %2F) or '\' (%5c or %5C)
            if (std.ascii.eqlIgnoreCase(hex, "2f") or std.ascii.eqlIgnoreCase(hex, "5c")) {
                return false;
            }
        }

        prev_char = c;
    }
    return true;
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

test "isPathSafe blocks path traversal attacks" {
    const testing = std.testing;

    // Safe paths
    try testing.expect(isPathSafe("/index.html"));
    try testing.expect(isPathSafe("/static/style.css"));
    try testing.expect(isPathSafe("/images/logo.png"));
    try testing.expect(isPathSafe("/api/users"));
    try testing.expect(isPathSafe("/a.b.c.html")); // Multiple dots but not ".."

    // Unsafe paths - ".." traversal
    try testing.expect(!isPathSafe("/.."));
    try testing.expect(!isPathSafe("/../"));
    try testing.expect(!isPathSafe("/static/../etc/passwd"));
    try testing.expect(!isPathSafe("/..hidden"));

    // Unsafe paths - encoded traversal
    try testing.expect(!isPathSafe("/%2e%2e/etc/passwd")); // %2e%2e = ..
    try testing.expect(!isPathSafe("/%2e.")); // %2e. = ..
    try testing.expect(!isPathSafe("/.%2e")); // .%2e = ..
    try testing.expect(!isPathSafe("/%2f")); // encoded /
    try testing.expect(!isPathSafe("/%5c")); // encoded \

    // Unsafe paths - backslash
    try testing.expect(!isPathSafe("/static\\..\\etc\\passwd"));
    try testing.expect(!isPathSafe("\\"));

    // Unsafe paths - null byte
    try testing.expect(!isPathSafe("/file.txt\x00.jpg"));
}

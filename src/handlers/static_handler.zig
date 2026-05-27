//! Static File Handler
//!
//! Serves static files from the configured static directory.
//! Uses FileCache for efficient file content and ETag caching.
//! Supports ETag caching, content type detection, and security headers.

const std = @import("std");
const httpz = @import("httpz");
const security = @import("../security/security.zig");
const file_cache_mod = @import("../cache/file_cache.zig");
const FileCache = file_cache_mod.FileCache;
const AppContext = @import("context.zig").AppContext;

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB max file size

/// Serve static files from the configured directory
/// Uses the shared FileCache to cache file content and ETags across requests.
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
    const static_dir_abs: []const u8 = if (ctx.static_dir_abs[0] != 0) ctx.static_dir_abs[0..] else blk: {
        // Fallback: compute the path if not cached (should rarely happen).
        // Uses arena allocator which is automatically cleaned up with the response.
        break :blk std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ctx.config.static_dir, res.arena) catch {
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
    const target_abs = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, joined_path, res.arena) catch {
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

    // Use the shared file cache to load file content and ETag efficiently.
    // The cache handles: reload modes (force/auto/never), mtime checking, and ETag caching.
    // Content is cached across requests to avoid repeated file reads.
    // Use loadFileWithETagAlloc to allocate directly into response arena, avoiding double copy.
    const file_info = ctx.file_cache.loadFileWithETagAlloc(target_abs, res.arena) catch |err| {
        switch (err) {
            error.FileNotFound => {
                res.status = 404;
                res.body = "File Not Found";
                return;
            },
            error.OutOfMemory => {
                res.status = 500;
                res.body = "Internal Server Error";
                return;
            },
            else => {
                res.status = 500;
                res.body = "Internal Server Error";
                return;
            },
        }
    };
    // Content and etag are allocated in res.arena and will be freed automatically
    // when the response is complete. No explicit cleanup needed.

    // Check file size
    if (file_info.content.len > MAX_FILE_SIZE) {
        res.status = 413;
        res.body = "File too large";
        return;
    }

    // Handle ETag-based conditional requests
    if (ctx.config.enable_etag) {
        // Check If-None-Match header for conditional requests
        if (req.headers.get("if-none-match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, file_info.etag)) {
                // File hasn't changed, return 304 Not Modified
                res.status = 304;
                // ETag is already in response arena, use it directly
                res.headers.add("ETag", file_info.etag);
                res.body = "";
                return;
            }
        }

        // Add ETag header to response (already in response arena)
        res.headers.add("ETag", file_info.etag);
        // Add Cache-Control header for better caching
        res.headers.add("Cache-Control", "public, max-age=3600");
    }

    // Set content type
    res.content_type = getContentType(target_abs);

    // Add security headers if enabled
    if (ctx.config.security_headers) {
        addSecurityHeaders(res);
    }

    // Set response body directly - content is already in response arena
    res.body = file_info.content;
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
/// - ".." path components (path traversal)
/// - URL-encoded path traversal attempts (%2e%2e, %2f, %5c)
/// - Backslash (Windows-style path separator)
/// - Null bytes
fn isPathSafe(path: []const u8) bool {
    var i: usize = 0;
    var prev_char: u8 = 0;
    var prev_prev_char: u8 = 0;

    while (i < path.len) : (i += 1) {
        const c = path[i];

        // Check for null bytes
        if (c == 0) return false;

        // Check for backslash
        if (c == '\\') return false;

        // Check for ".." path component (path traversal)
        // The ".." must be a complete path component, not part of a filename like "..hidden" or "a..b"
        // Patterns to block: "/..", "../", start with ".." as a complete path component
        if (c == '.' and prev_char == '.') {
            // When we see ".." at position i (second dot), the first dot is at i-1
            // Check if this ".." is at a path boundary
            // at_start: ".." starts at position 0 (first dot at 0, second at 1)
            const at_start = i == 1;
            // after_slash: preceded by "/" (first dot right after slash)
            const after_slash = prev_prev_char == '/';
            // at_end: ".." is at end of path
            const at_end = i + 1 >= path.len;
            // before_slash: followed by "/"
            const before_slash = i + 1 < path.len and path[i + 1] == '/';

            // Block if ".." is a complete path component
            if ((at_start or after_slash) and (at_end or before_slash)) {
                return false;
            }
        }

        // Check for URL-encoded characters
        if (c == '%' and i + 3 <= path.len) {
            const hex = path[i + 1 .. i + 3];
            // Check for encoded '.' (%2e or %2E)
            if (std.ascii.eqlIgnoreCase(hex, "2e")) {
                // Look for pattern like %2e%2e or %2e. or .%2e
                if (i + 6 <= path.len and path[i + 3] == '%') {
                    const hex2 = path[i + 4 .. i + 6];
                    if (std.ascii.eqlIgnoreCase(hex2, "2e")) {
                        return false; // Found %2e%2e
                    }
                }
                if (i + 4 <= path.len and path[i + 3] == '.') {
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

        prev_prev_char = prev_char;
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

    // Safe paths - including legitimate filenames with dots
    try testing.expect(isPathSafe("/index.html"));
    try testing.expect(isPathSafe("/static/style.css"));
    try testing.expect(isPathSafe("/images/logo.png"));
    try testing.expect(isPathSafe("/api/users"));
    try testing.expect(isPathSafe("/a.b.c.html")); // Multiple dots but not ".." as path component
    try testing.expect(isPathSafe("/..hidden")); // ".." followed by more chars is valid filename
    try testing.expect(isPathSafe("/a..b.txt")); // ".." in middle of filename is valid

    // Unsafe paths - ".." path component traversal
    try testing.expect(!isPathSafe("/.."));
    try testing.expect(!isPathSafe("/../"));
    try testing.expect(!isPathSafe("/static/../etc/passwd"));
    try testing.expect(!isPathSafe("../etc/passwd"));

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

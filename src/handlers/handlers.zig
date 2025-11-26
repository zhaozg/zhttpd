const std = @import("std");
const Config = @import("../config/config.zig").Config;
const security = @import("../security/security.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    thread_pool: ?std.Thread.Pool = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Server {
        return Server{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.thread_pool) |*pool| {
            pool.deinit();
        }
    }

    pub fn start(self: *Server) !void {
        std.debug.print("Server starting on {s}:{d}\n", .{ self.config.host, self.config.port });

        // Initialize thread pool
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = self.allocator, .n_jobs = self.config.thread_pool_size });
        self.thread_pool = pool;

        // Create socket address
        const address = try std.net.Address.parseIp(self.config.host, self.config.port);

        // Create listening socket
        var server = try address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        std.debug.print("Listening on {s}:{d}\n", .{ self.config.host, self.config.port });
        std.debug.print("Press Ctrl+C to stop\n", .{});

        // Accept connections
        while (true) {
            const connection = try server.accept();
            try self.handleConnection(connection);
        }
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        const request = buffer[0..bytes_read];

        // Parse HTTP request
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.next() orelse return error.InvalidRequest;

        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;

        std.debug.print("{s} {s}\n", .{ method, path });

        // Route the request
        if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) {
            try self.handleGet(connection.stream, path);
        } else if (std.mem.eql(u8, method, "POST")) {
            try self.handlePost(connection.stream, path);
        } else {
            try self.sendResponse(connection.stream, "405 Method Not Allowed", "text/plain", "Method Not Allowed");
        }
    }

    fn handleGet(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Check if this is a GraphQL endpoint
        if (self.config.enable_graphql and std.mem.eql(u8, path, self.config.graphql_endpoint)) {
            try self.sendResponse(stream, "200 OK", "application/json",
                \\{"data":{"message":"GraphQL endpoint - use POST for queries"}}
            );
            return;
        }

        // Serve static files
        try self.serveStaticFile(stream, path);
    }

    fn handlePost(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Check if this is a GraphQL endpoint
        if (self.config.enable_graphql and std.mem.eql(u8, path, self.config.graphql_endpoint)) {
            try self.sendResponse(stream, "200 OK", "application/json",
                \\{"data":{"message":"GraphQL query executed"}}
            );
            return;
        }

        // Check if this is a Lua handler
        if (self.config.enable_lua and std.mem.startsWith(u8, path, "/api/")) {
            try self.handleLuaApi(stream, path);
            return;
        }

        try self.sendResponse(stream, "404 Not Found", "text/plain", "Not Found");
    }

    fn serveStaticFile(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Normalize path and prevent directory traversal
        const clean_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;

        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ self.config.static_dir, clean_path });

        // Try to open the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try self.sendResponse(stream, "404 Not Found", "text/plain", "File Not Found");
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 10);
        defer self.allocator.free(content);

        // Determine content type
        const content_type = getContentType(file_path);

        try self.sendResponse(stream, "200 OK", content_type, content);
    }

    fn handleLuaApi(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        _ = path;

        // Lua integration would go here
        try self.sendResponse(stream, "200 OK", "application/json",
            \\{"message":"Lua API handler","status":"placeholder"}
        );
    }

    fn sendResponse(self: *Server, stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
        var response_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        // Build HTTP response header
        const header_part1 = try std.fmt.bufPrint(response_buf[pos..],
            \\HTTP/1.1 {s}
            \\Content-Type: {s}
            \\Content-Length: {d}
            \\Connection: close
            \\
        , .{ status, content_type, body.len });
        pos += header_part1.len;

        // Add security headers if enabled
        if (self.config.security_headers) {
            const headers = security.default_headers;
            const security_headers = try std.fmt.bufPrint(response_buf[pos..],
                \\Content-Security-Policy: {s}
                \\X-Frame-Options: {s}
                \\X-Content-Type-Options: {s}
                \\X-XSS-Protection: {s}
                \\Strict-Transport-Security: {s}
                \\Referrer-Policy: {s}
                \\Permissions-Policy: {s}
                \\
            , .{
                headers.csp,
                headers.x_frame_options,
                headers.x_content_type_options,
                headers.x_xss_protection,
                headers.hsts,
                headers.referrer_policy,
                headers.permissions_policy,
            });
            pos += security_headers.len;
        }

        // Add blank line
        response_buf[pos] = '\r';
        pos += 1;
        response_buf[pos] = '\n';
        pos += 1;

        // Send headers
        _ = try stream.write(response_buf[0..pos]);

        // Send body
        _ = try stream.write(body);
    }
};

fn getContentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

test "content type detection" {
    const testing = std.testing;
    try testing.expectEqualStrings("text/html; charset=utf-8", getContentType("/index.html"));
    try testing.expectEqualStrings("text/css; charset=utf-8", getContentType("/style.css"));
    try testing.expectEqualStrings("application/javascript; charset=utf-8", getContentType("/app.js"));
    try testing.expectEqualStrings("application/json; charset=utf-8", getContentType("/data.json"));
}

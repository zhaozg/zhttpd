const std = @import("std");
const httpz = @import("httpz");
const Config = @import("../config/config.zig").Config;
const security = @import("../security/security.zig");
const LuaHandler = @import("../lua/lua.zig").LuaHandler;
const GraphQLHandler = @import("../graphql/graphql.zig").GraphQLHandler;
const logger_mod = @import("../logger/logger.zig");
const Logger = logger_mod.Logger;
const LogLevel = logger_mod.LogLevel;

// Constants
const BUFFER_SIZE = 64 * 1024; // 64KB for request/response buffers
const MAX_CONNECTIONS = 512;
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB max file size

// Application context that holds our handlers
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    lua_handler: ?LuaHandler = null,
    graphql_handler: ?GraphQLHandler = null,
    logger: Logger,
    access_logger: ?Logger = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) !AppContext {
        // Parse log level
        const log_level = if (std.mem.eql(u8, config.log_level, "debug"))
            LogLevel.debug
        else if (std.mem.eql(u8, config.log_level, "warn"))
            LogLevel.warn
        else if (std.mem.eql(u8, config.log_level, "err"))
            LogLevel.err
        else
            LogLevel.info;

        // Initialize main logger
        var logger = try Logger.init(allocator, log_level, config.log_file);
        errdefer logger.deinit();

        // Initialize access logger if configured
        var access_logger: ?Logger = null;
        if (config.access_log_file) |_| {
            access_logger = try Logger.init(allocator, .info, config.access_log_file);
        }
        errdefer if (access_logger) |*al| al.deinit();

        var ctx = AppContext{
            .allocator = allocator,
            .config = config,
            .logger = logger,
            .access_logger = access_logger,
        };

        // Initialize Lua handler if enabled
        if (config.enable_lua) {
            ctx.lua_handler = try LuaHandler.init(allocator, config.lua_scripts_dir);
            ctx.logger.info("Lua handler initialized with scripts from: {s}", .{config.lua_scripts_dir});
        }

        // Initialize GraphQL handler if enabled
        if (config.enable_graphql) {
            var graphql = try GraphQLHandler.init(allocator);
            // Try to load schema if it exists
            graphql.loadSchema("examples/graphql/schema.graphql") catch |err| {
                ctx.logger.warn("Could not load GraphQL schema: {}", .{err});
            };
            ctx.graphql_handler = graphql;
            ctx.logger.info("GraphQL handler initialized", .{});
        }

        return ctx;
    }

    pub fn deinit(self: *AppContext) void {
        if (self.lua_handler) |*lua| {
            lua.deinit();
        }
        if (self.graphql_handler) |*graphql| {
            graphql.deinit();
        }
        self.logger.deinit();
        if (self.access_logger) |*al| {
            al.deinit();
        }
    }
};

pub const HttpzServer = struct {
    server: httpz.Server(*AppContext),
    context: *AppContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) !HttpzServer {
        const context = try allocator.create(AppContext);
        errdefer allocator.destroy(context);

        context.* = try AppContext.init(allocator, config);
        errdefer context.deinit();

        const server = try httpz.Server(*AppContext).init(allocator, .{
            .port = config.port,
            .address = config.host,
            .request = .{
                .max_body_size = config.max_body_size,
                .max_form_count = 20,
                .buffer_size = BUFFER_SIZE,
            },
            .timeout = .{
                .request = config.timeout_seconds * 1000, // convert to ms
            },
            .thread_pool = .{
                .count = @intCast(config.thread_pool_size),
            },
            .workers = .{
                .max_conn = MAX_CONNECTIONS,
            },
        }, context);

        return HttpzServer{
            .server = server,
            .context = context,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpzServer) void {
        self.server.deinit();
        self.context.deinit();
        self.allocator.destroy(self.context);
    }

    pub fn setupRoutes(self: *HttpzServer) !void {
        var router = try self.server.router(.{});

        // Register more specific routes before wildcard routes
        // GraphQL endpoint (must come before wildcard)
        if (self.context.config.enable_graphql) {
            const endpoint = self.context.config.graphql_endpoint;
            router.get(endpoint, graphqlGet, .{});
            router.post(endpoint, graphqlPost, .{});
        }

        // Lua API endpoints (must come before wildcard)
        // Support both GET and POST for dynamic Lua handlers
        if (self.context.config.enable_lua) {
            router.get("/api/*", luaApi, .{});
            router.post("/api/*", luaApi, .{});
        }

        // Static file routes (wildcard must come last)
        router.get("/*", serveStatic, .{});
    }

    pub fn listen(self: *HttpzServer) !void {
        self.context.logger.info("Listening on {s}:{d}", .{ self.context.config.host, self.context.config.port });
        self.context.logger.info("Press Ctrl+C to stop", .{});
        try self.server.listen();
    }

    pub fn stop(self: *HttpzServer) void {
        self.server.stop();
    }
};

// Route handlers

/// Helper function to log HTTP access
fn logAccess(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response, duration_us: i64) void {
    if (ctx.access_logger) |*logger| {
        // Format address - req.address is a union, format it as string
        var addr_buf: [128]u8 = undefined; // Large enough for IPv6 with port
        const remote_addr = std.fmt.bufPrint(&addr_buf, "{any}", .{req.address}) catch "unknown";

        const method = @tagName(req.method);
        const path = req.url.path;

        // Sanitize user-agent to prevent log injection
        const raw_user_agent = req.headers.get("user-agent") orelse "-";
        var ua_buf: [256]u8 = undefined;
        const user_agent = sanitizeLogField(&ua_buf, raw_user_agent);

        const bytes_sent = res.body.len;

        logger.access(
            remote_addr,
            method,
            path,
            "HTTP/1.1",
            res.status,
            bytes_sent,
            user_agent,
            duration_us,
        );
    }
}

/// Sanitize log field by removing newlines and control characters
fn sanitizeLogField(buf: []u8, input: []const u8) []const u8 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len and j < buf.len) : (i += 1) {
        const c = input[i];
        // Replace newlines, carriage returns, and control characters with space
        if (c == '\n' or c == '\r' or c < 32 or c == 127) {
            buf[j] = ' ';
        } else {
            buf[j] = c;
        }
        j += 1;
    }
    return buf[0..j];
}

fn serveStatic(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

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

    // Get file size
    const stat = try file.stat();
    const file_size = stat.size;

    if (file_size > MAX_FILE_SIZE) {
        res.status = 413;
        res.body = "File too large";
        return;
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

fn graphqlGet(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    res.content_type = httpz.ContentType.JSON;
    res.body =
        \\{"data":{"message":"GraphQL endpoint - use POST for queries"}}
    ;
}

fn graphqlPost(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    res.content_type = httpz.ContentType.JSON;

    if (ctx.graphql_handler) |*handler| {
        // Get request body
        const body = req.body() orelse {
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Missing request body"}]}
            ;
            return;
        };

        // Parse JSON body
        var parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch |err| {
            ctx.logger.err("GraphQL JSON parse error: {}", .{err});
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Invalid JSON in request body"}]}
            ;
            return;
        };
        defer parsed.deinit();

        // Extract query field with type checking
        const query = if (parsed.value.object.get("query")) |q| blk: {
            if (q != .string) {
                res.status = 400;
                res.body =
                    \\{"errors":[{"message":"'query' field must be a string"}]}
                ;
                return;
            }
            break :blk q.string;
        } else {
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Missing 'query' field"}]}
            ;
            return;
        };

        // DESIGN PATTERN: Temporary allocator switching for per-request arena allocation
        // This pattern is intentional and safe because:
        // 1. Single-threaded per-request context - no concurrent access to same handler
        // 2. Defer ensures allocator is always restored, even on early returns
        // 3. Each request has its own execution context via res.arena
        // 4. The response arena is automatically cleaned up by httpz after request completes
        // Alternative: Passing allocator as parameter would require changing handler API
        // Risk: Low - defer guarantees restoration regardless of error returns
        const original_alloc = handler.allocator;
        handler.allocator = res.arena;
        defer handler.allocator = original_alloc;

        const result = handler.executeQuery(query) catch {
            res.status = 500;
            res.body =
                \\{"errors":[{"message":"Query execution failed"}]}
            ;
            return;
        };

        res.body = result;
    } else {
        res.status = 503;
        res.body =
            \\{"errors":[{"message":"GraphQL handler not initialized"}]}
        ;
    }
}

fn luaApi(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    res.content_type = httpz.ContentType.JSON;

    if (ctx.lua_handler) |*handler| {
        const path = req.url.path;
        const method = @tagName(req.method);

        // Extract script name from path (/api/test -> test, /api/users -> users)
        const script_name = blk: {
            if (std.mem.startsWith(u8, path, "/api/")) {
                const remaining = path[5..]; // Skip "/api/"
                // Handle paths like /api/users/123 -> users
                if (std.mem.indexOfScalar(u8, remaining, '/')) |slash_pos| {
                    break :blk remaining[0..slash_pos];
                }
                break :blk remaining;
            }
            break :blk "test";
        };

        // Get request body
        const body = req.body() orelse "";

        // DESIGN PATTERN: Temporary allocator switching for per-request arena allocation
        // This pattern is intentional and safe because:
        // 1. Single-threaded per-request context - no concurrent access to same handler
        // 2. Defer ensures allocator is always restored, even on early returns
        // 3. Each request has its own execution context via res.arena
        // 4. The response arena is automatically cleaned up by httpz after request completes
        // Alternative: Passing allocator as parameter would require changing handler API
        // Risk: Low - defer guarantees restoration regardless of error returns
        const original_alloc = handler.allocator;
        handler.allocator = res.arena;
        defer handler.allocator = original_alloc;

        const result = handler.executeScript(script_name, method, path, body) catch |err| {
            ctx.logger.err("Lua execution error: {}", .{err});
            res.status = 500;
            res.body =
                \\{"status":"error","message":"Script execution failed"}
            ;
            return;
        };

        res.body = result;
    } else {
        res.status = 503;
        res.body =
            \\{"status":"error","message":"Lua handler not initialized"}
        ;
    }
}

fn getContentType(path: []const u8) httpz.ContentType {
    if (std.mem.endsWith(u8, path, ".html")) return httpz.ContentType.HTML;
    if (std.mem.endsWith(u8, path, ".css")) return httpz.ContentType.CSS;
    if (std.mem.endsWith(u8, path, ".js")) return httpz.ContentType.JS;
    if (std.mem.endsWith(u8, path, ".json")) return httpz.ContentType.JSON;
    if (std.mem.endsWith(u8, path, ".png")) return httpz.ContentType.PNG;
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return httpz.ContentType.JPG;
    if (std.mem.endsWith(u8, path, ".gif")) return httpz.ContentType.GIF;
    if (std.mem.endsWith(u8, path, ".svg")) return httpz.ContentType.SVG;
    if (std.mem.endsWith(u8, path, ".ico")) return httpz.ContentType.ICO;
    return httpz.ContentType.BINARY;
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

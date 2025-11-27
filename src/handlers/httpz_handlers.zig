const std = @import("std");
const httpz = @import("httpz");
const Config = @import("../config/config.zig").Config;
const security = @import("../security/security.zig");
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
const KeyValue = lua_mod.KeyValue;
const GraphQLHandler = @import("../graphql/graphql.zig").GraphQLHandler;
const logger_mod = @import("../logger/logger.zig");
const Logger = logger_mod.Logger;
const LogLevel = logger_mod.LogLevel;
const FileCache = @import("../cache/file_cache.zig").FileCache;
const middleware = @import("../middleware/middleware.zig");
const RateLimiter = middleware.RateLimiter;
const CorsMiddleware = middleware.CorsMiddleware;
const AuthMiddleware = middleware.AuthMiddleware;

// Constants
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB max file size
const MAX_HEADERS_FOR_LUA = 32; // Maximum number of headers to pass to Lua
const MAX_QUERY_PARAMS_FOR_LUA = 32; // Maximum number of query params to pass to Lua

// Application context that holds our handlers
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    file_cache: *FileCache, // Global file cache shared by all handlers
    lua_handler: ?LuaHandler = null,
    graphql_handler: ?GraphQLHandler = null,
    logger: Logger,
    access_logger: ?Logger = null,
    // Phase 3: Middleware
    rate_limiter: ?*RateLimiter = null,
    cors_middleware: ?CorsMiddleware = null,
    auth_middleware: ?AuthMiddleware = null,

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

        // Initialize global file cache
        const file_cache = try allocator.create(FileCache);
        errdefer allocator.destroy(file_cache);
        file_cache.* = FileCache.init(allocator, config.reload, config.max_cache_file_size);
        errdefer file_cache.deinit();

        var ctx = AppContext{
            .allocator = allocator,
            .config = config,
            .file_cache = file_cache,
            .logger = logger,
            .access_logger = access_logger,
        };

        // Initialize Lua handler if enabled
        if (config.enable_lua) {
            ctx.lua_handler = try LuaHandler.init(allocator, config.lua_scripts_dir, file_cache);
            errdefer if (ctx.lua_handler) |*lua| lua.deinit();
            ctx.logger.info("Lua handler initialized with scripts from: {s} (reload: {s}, max_cache_file_size: {})", .{ config.lua_scripts_dir, @tagName(config.reload), config.max_cache_file_size });
        }

        // Initialize GraphQL handler if enabled
        if (config.enable_graphql) {
            var graphql = try GraphQLHandler.init(allocator);
            errdefer graphql.deinit();
            // Try to load schema if it exists
            graphql.loadSchema("examples/graphql/schema.graphql") catch |err| {
                ctx.logger.warn("Could not load GraphQL schema: {}", .{err});
            };
            ctx.graphql_handler = graphql;
            ctx.logger.info("GraphQL handler initialized", .{});
        }

        // Phase 3: Initialize middleware

        // Initialize rate limiter if enabled
        if (config.enable_rate_limit) {
            const rate_limiter = try allocator.create(RateLimiter);
            errdefer allocator.destroy(rate_limiter);
            rate_limiter.* = RateLimiter.init(allocator, .{
                .max_requests = config.rate_limit_requests,
                .window_seconds = config.rate_limit_window,
                .per_ip = true,
                .burst_size = 10,
            });
            ctx.rate_limiter = rate_limiter;
            ctx.logger.info("Rate limiter initialized: {d} requests per {d} seconds", .{ config.rate_limit_requests, config.rate_limit_window });
        }

        // Initialize CORS middleware if enabled
        if (config.enable_cors) {
            ctx.cors_middleware = CorsMiddleware.init(.{
                .enabled = true,
                .allowed_origins = config.cors_origins,
                .allowed_methods = config.cors_methods,
                .allowed_headers = config.cors_headers,
            });
            ctx.logger.info("CORS middleware initialized with origins: {s}", .{config.cors_origins});
        }

        // Initialize auth middleware if enabled
        if (config.enable_auth) {
            ctx.auth_middleware = AuthMiddleware.init(.{
                .enabled = true,
                .auth_script = config.auth_script,
                .protected_paths = config.auth_protected_paths,
                .public_paths = config.auth_public_paths,
            });
            ctx.logger.info("Auth middleware initialized, protected paths: {s}", .{config.auth_protected_paths});
        }

        // Log WebSocket and SSE status
        if (config.enable_websocket) {
            ctx.logger.info("WebSocket support enabled", .{});
        }
        if (config.enable_sse) {
            ctx.logger.info("Server-Sent Events (SSE) support enabled", .{});
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
        if (self.rate_limiter) |rate_limiter| {
            rate_limiter.deinit();
            self.allocator.destroy(rate_limiter);
        }
        self.file_cache.deinit();
        self.allocator.destroy(self.file_cache);
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
                .buffer_size = config.request_buffer_size,
            },
            .timeout = .{
                .request = config.timeout_seconds * 1000, // convert to ms
            },
            .thread_pool = .{
                .count = @intCast(config.thread_pool_size),
            },
            .workers = .{
                .max_conn = @intCast(config.max_connections),
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

        // SSE endpoint (if enabled)
        if (self.context.config.enable_sse) {
            router.get("/events", sseHandler, .{});
        }
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

/// Apply middleware checks (rate limiting, CORS, auth)
/// Returns true if request should proceed, false if blocked
fn applyMiddleware(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) bool {
    // Rate limiting check
    if (ctx.rate_limiter) |rate_limiter| {
        // Extract client IP from address
        var addr_buf: [128]u8 = undefined;
        const client_ip = std.fmt.bufPrint(&addr_buf, "{any}", .{req.address}) catch null;

        if (!rate_limiter.checkRequest(client_ip)) {
            res.status = 429; // Too Many Requests
            res.body =
                \\{"error":"Too Many Requests","message":"Rate limit exceeded. Please try again later."}
            ;
            // Use actual rate_limit_window config value for Retry-After
            var retry_after_buf: [16]u8 = undefined;
            const retry_after_str = std.fmt.bufPrint(&retry_after_buf, "{d}", .{ctx.config.rate_limit_window}) catch "60";
            res.headers.add("Retry-After", retry_after_str);
            res.headers.add("Content-Type", "application/json");
            return false;
        }

        // Add rate limit headers
        const remaining = rate_limiter.getRemainingTokens(client_ip);
        var remaining_buf: [16]u8 = undefined;
        const remaining_str = std.fmt.bufPrint(&remaining_buf, "{d}", .{remaining}) catch "0";
        res.headers.add("X-RateLimit-Remaining", remaining_str);
    }

    // CORS handling
    if (ctx.cors_middleware) |*cors| {
        if (req.headers.get("origin")) |origin| {
            if (cors.getHeaders(origin)) |cors_headers| {
                res.headers.add("Access-Control-Allow-Origin", cors_headers.access_control_allow_origin);
                res.headers.add("Access-Control-Allow-Methods", cors_headers.access_control_allow_methods);
                res.headers.add("Access-Control-Allow-Headers", cors_headers.access_control_allow_headers);
                res.headers.add("Access-Control-Expose-Headers", cors_headers.access_control_expose_headers);

                if (cors_headers.access_control_allow_credentials) {
                    res.headers.add("Access-Control-Allow-Credentials", "true");
                }

                // Handle preflight requests
                if (req.method == .OPTIONS) {
                    res.status = 204;
                    res.body = "";
                    // Add max-age header for preflight caching
                    var max_age_buf: [16]u8 = undefined;
                    const max_age_str = std.fmt.bufPrint(&max_age_buf, "{d}", .{cors_headers.access_control_max_age}) catch "0";
                    res.headers.add("Access-Control-Max-Age", max_age_str);
                    return false;
                }
            }
        }
    }

    // Authentication check (delegates to Lua for actual validation)
    if (ctx.auth_middleware) |*auth| {
        if (auth.requiresAuth(req.url.path)) {
            const auth_header = req.headers.get(auth.config.token_header) orelse {
                res.status = 401;
                res.body =
                    \\{"error":"Unauthorized","message":"Authentication required"}
                ;
                res.headers.add("WWW-Authenticate", "Bearer");
                res.headers.add("Content-Type", "application/json");
                return false;
            };

            const token = auth.extractToken(auth_header) orelse {
                res.status = 401;
                res.body =
                    \\{"error":"Unauthorized","message":"Invalid authorization header format"}
                ;
                res.headers.add("Content-Type", "application/json");
                return false;
            };

            // If Lua handler is available, delegate token validation to Lua auth script
            if (ctx.lua_handler) |*handler| {
                const method = @tagName(req.method);
                const auth_request = auth.buildAuthRequest(res.arena, token, method, req.url.path) catch {
                    res.status = 500;
                    res.body =
                        \\{"error":"Internal Server Error","message":"Failed to build auth request"}
                    ;
                    res.headers.add("Content-Type", "application/json");
                    return false;
                };

                const result = handler.executeScript(res.arena, auth.config.auth_script, "POST", "/auth/validate", auth_request) catch {
                    res.status = 500;
                    res.body =
                        \\{"error":"Internal Server Error","message":"Auth script execution failed"}
                    ;
                    res.headers.add("Content-Type", "application/json");
                    return false;
                };

                // Parse auth result using proper JSON parsing
                const auth_response = std.json.parseFromSlice(std.json.Value, res.arena, result, .{}) catch {
                    // If JSON parsing fails, treat as unauthenticated
                    res.status = 500;
                    res.body =
                        \\{"error":"Internal Server Error","message":"Invalid auth response format"}
                    ;
                    res.headers.add("Content-Type", "application/json");
                    return false;
                };

                // Check if authenticated field is true
                const authenticated = if (auth_response.value == .object)
                    if (auth_response.value.object.get("authenticated")) |auth_val|
                        auth_val == .bool and auth_val.bool
                    else
                        false
                else
                    false;

                if (!authenticated) {
                    res.status = 403;
                    res.body = result; // Return the auth script's response
                    res.headers.add("Content-Type", "application/json");
                    return false;
                }
            } else {
                // No Lua handler, just check that token exists (basic validation)
                if (token.len == 0) {
                    res.status = 401;
                    res.body =
                        \\{"error":"Unauthorized","message":"Empty token"}
                    ;
                    res.headers.add("Content-Type", "application/json");
                    return false;
                }
            }
        }
    }

    return true;
}

/// Helper function to log HTTP access
fn logAccess(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response, duration_us: i64) void {
    if (ctx.access_logger) |*logger| {
        // Format address - req.address is a union, format it as string
        var addr_buf: [128]u8 = undefined; // Large enough for IPv6 with port
        const remote_addr = std.fmt.bufPrint(&addr_buf, "{any}", .{req.address}) catch "unknown";

        const method = @tagName(req.method);

        // Sanitize path to prevent log injection
        var path_buf: [512]u8 = undefined;
        const path = sanitizeLogField(&path_buf, req.url.path);

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
/// Returns the sanitized string. If input is longer than buffer, it will be truncated.
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
    // Log warning if truncation occurred (security consideration)
    if (i < input.len) {
        std.debug.print("Warning: Log field truncated from {} to {} bytes\n", .{ input.len, j });
    }
    return buf[0..j];
}

/// Server-Sent Events (SSE) handler
/// Sends a stream of events to the client
fn sseHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
    }

    ctx.logger.debug("SSE connection established from client", .{});

    // Start event stream (synchronous mode for simpler handling)
    const stream = res.startEventStreamSync() catch |err| {
        ctx.logger.err("Failed to start SSE stream: {}", .{err});
        res.status = 500;
        res.body = "Failed to start event stream";
        return;
    };

    // Send a welcome event
    _ = stream.write("event: connected\ndata: {\"status\":\"connected\",\"message\":\"SSE stream established\"}\n\n") catch |err| {
        ctx.logger.warn("Failed to write SSE welcome event: {}", .{err});
        return;
    };

    // Send a heartbeat event with actual timestamp
    var heartbeat_buf: [128]u8 = undefined;
    const timestamp = std.time.timestamp();
    const heartbeat_data = std.fmt.bufPrint(&heartbeat_buf, "event: heartbeat\ndata: {{\"timestamp\":{d}}}\n\n", .{timestamp}) catch {
        ctx.logger.warn("Failed to format SSE heartbeat", .{});
        return;
    };
    _ = stream.write(heartbeat_data) catch |err| {
        ctx.logger.warn("Failed to write SSE heartbeat: {}", .{err});
        return;
    };

    ctx.logger.debug("SSE events sent successfully", .{});
}

fn serveStatic(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
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

fn graphqlGet(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
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

    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
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
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch |err| {
            ctx.logger.err("GraphQL JSON parse error: {}", .{err});
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Invalid JSON in request body"}]}
            ;
            return;
        };
        // No defer needed for arena-allocated memory

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

        // Use the response arena allocator for per-request allocations
        const result = handler.executeQuery(res.arena, query) catch {
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

    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
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

        // Extract headers for Lua (luvit/Node.js style)
        var headers_buf: [MAX_HEADERS_FOR_LUA]KeyValue = undefined;
        var headers_count: usize = 0;
        var header_iter = req.headers.iterator();
        while (header_iter.next()) |entry| {
            if (headers_count >= MAX_HEADERS_FOR_LUA) break;
            headers_buf[headers_count] = KeyValue{
                .key = entry.key,
                .value = entry.value,
            };
            headers_count += 1;
        }
        const headers = headers_buf[0..headers_count];

        // Extract query parameters for Lua (luvit/Node.js style)
        // Note: URL decoding is not performed here - parameters with encoded
        // characters (like %20 for spaces) will remain encoded. Full URL decoding
        // should be implemented in a future enhancement if needed.
        var query_buf: [MAX_QUERY_PARAMS_FOR_LUA]KeyValue = undefined;
        var query_count: usize = 0;

        // Parse query string from URL if present
        if (req.url.query.len > 0) {
            var query_iter = std.mem.splitScalar(u8, req.url.query, '&');
            while (query_iter.next()) |param| {
                if (query_count >= MAX_QUERY_PARAMS_FOR_LUA) break;
                if (std.mem.indexOfScalar(u8, param, '=')) |eq_pos| {
                    query_buf[query_count] = KeyValue{
                        .key = param[0..eq_pos],
                        .value = if (eq_pos + 1 < param.len) param[eq_pos + 1 ..] else "",
                    };
                    query_count += 1;
                }
            }
        }
        const query_params = query_buf[0..query_count];

        // Use the response arena allocator for per-request allocations
        // This ensures all allocations are automatically cleaned up after the response
        const result = handler.executeScriptEx(res.arena, script_name, method, path, body, headers, query_params) catch |err| {
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

// Tests
test "sanitizeLogField removes newlines and control characters" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    // Test newline removal
    const input1 = "test\nvalue";
    const result1 = sanitizeLogField(&buf, input1);
    try testing.expectEqualStrings("test value", result1);

    // Test carriage return removal
    const input2 = "test\rvalue";
    const result2 = sanitizeLogField(&buf, input2);
    try testing.expectEqualStrings("test value", result2);

    // Test control character removal
    const input3 = "test\x00value";
    const result3 = sanitizeLogField(&buf, input3);
    try testing.expectEqualStrings("test value", result3);

    // Test normal string passes through
    const input4 = "normal string";
    const result4 = sanitizeLogField(&buf, input4);
    try testing.expectEqualStrings("normal string", result4);
}

test "sanitizeLogField handles buffer overflow" {
    const testing = std.testing;

    var small_buf: [10]u8 = undefined;

    // Input longer than buffer
    const long_input = "this is a very long string";
    const result = sanitizeLogField(&small_buf, long_input);

    // Should be truncated to buffer size
    try testing.expect(result.len == 10);
    try testing.expectEqualStrings("this is a ", result);
}

test "sanitizeLogField handles empty input" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    const result = sanitizeLogField(&buf, "");
    try testing.expect(result.len == 0);
}

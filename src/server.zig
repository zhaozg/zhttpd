//! zhttpd HTTP Server
//!
//! This module implements the core HTTP server for zhttpd.
//! It follows an event-driven, middleware-based architecture inspired by
//! Apache httpd, Nginx, and OpenResty.
//!
//! ## Architecture Overview
//!
//! Request processing follows this flow:
//! 1. Request ID generation/propagation
//! 2. IP access control (blacklist/whitelist)
//! 3. Rate limiting (token bucket)
//! 4. CORS handling
//! 5. Authentication (Lua-delegated)
//! 6. Route matching
//! 7. Handler execution
//! 8. Security headers
//! 9. Access logging & metrics
//!
//! ## Key Components
//!
//! - `AppContext`: Shared application state (handlers, caches, middleware)
//! - `HttpzServer`: Server wrapper with route configuration
//! - `applyMiddleware`: Middleware chain execution
//!
//! ## Extension Points
//!
//! To add a new handler:
//! 1. Create a handler function following the pattern:
//!    ```zig
//!    fn myHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void
//!    ```
//! 2. Register the route in `setupRoutes()`
//!
//! See `docs/HTTP_REQUEST_HANDLING.md` for detailed design documentation.

const std = @import("std");
const httpz = @import("httpz");
const config_mod = @import("config/config.zig");
const Config = config_mod.Config;
const HandlerMapping = config_mod.HandlerMapping;
const security = @import("security/security.zig");
// Phase 5: Observability
const observability = @import("observability/observability.zig");
const request_id = observability.request_id;
// Re-export AppContext from handlers/context.zig
pub const AppContext = @import("handlers/context.zig").AppContext;
// Individual handler modules
const static_handler = @import("handlers/static_handler.zig");
const lua_handler = @import("handlers/lua_handler.zig");
const health_handler = @import("handlers/health_handler.zig");
const metrics_handler = @import("handlers/metrics_handler.zig");
const sse_handler = @import("handlers/sse_handler.zig");
const websocket_handler = @import("handlers/websocket_handler.zig");

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
        const router = try self.server.router(.{});

        // Register routes based on handler configuration
        // Routes are processed in order, so more specific routes should come first
        for (self.context.config.handlers) |mapping| {
            self.registerHandler(router, mapping);
        }

        // Log registered handlers
        self.context.logger.info("Registered {d} handler mappings from configuration", .{self.context.config.handlers.len});
    }

    /// Register a single handler mapping with the router
    fn registerHandler(self: *HttpzServer, router: anytype, mapping: HandlerMapping) void {
        const pattern = mapping.pattern;
        const handler_name = mapping.handler;

        // Check feature flags and skip disabled handlers with warning
        if (std.mem.eql(u8, handler_name, "Handler.HealthCheckHandler")) {
            if (!self.context.config.enable_health_check) {
                self.context.logger.warn("Skipping {s} at {s} - health check feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, healthHandler, .{});
            self.context.logger.debug("Registered HealthCheckHandler at {s}", .{pattern});
        } else if (std.mem.eql(u8, handler_name, "Handler.MetricsHandler")) {
            if (!self.context.config.enable_metrics) {
                self.context.logger.warn("Skipping {s} at {s} - metrics feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, metricsHandler, .{});
            self.context.logger.debug("Registered MetricsHandler at {s}", .{pattern});
        } else if (std.mem.eql(u8, handler_name, "Handler.WebSocketHandler")) {
            if (!self.context.config.enable_websocket) {
                self.context.logger.warn("Skipping {s} at {s} - websocket feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, websocketHandler, .{});
            self.context.logger.debug("Registered WebSocketHandler at {s}", .{pattern});
        } else if (std.mem.eql(u8, handler_name, "Handler.LuaHandler")) {
            if (!self.context.config.enable_lua) {
                self.context.logger.warn("Skipping {s} at {s} - lua feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, luaApi, .{});
            router.post(pattern, luaApi, .{});
            self.context.logger.debug("Registered LuaHandler at {s}", .{pattern});
        } else if (std.mem.eql(u8, handler_name, "Handler.SSEHandler")) {
            if (!self.context.config.enable_sse) {
                self.context.logger.warn("Skipping {s} at {s} - sse feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, sseHandler, .{});
            self.context.logger.debug("Registered SSEHandler at {s}", .{pattern});
        } else if (std.mem.eql(u8, handler_name, "Handler.StaticFileHandler")) {
            router.get(pattern, serveStatic, .{});
            self.context.logger.debug("Registered StaticFileHandler at {s}", .{pattern});
        } else {
            self.context.logger.warn("Unknown handler: {s} for pattern {s}", .{ handler_name, pattern });
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

/// Apply middleware checks (IP access control, rate limiting, CORS, auth)
/// Returns true if request should proceed, false if blocked
fn applyMiddleware(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) bool {
    // Extract client IP from address for use in multiple checks
    var addr_buf: [128]u8 = undefined;
    const client_ip = std.fmt.bufPrint(&addr_buf, "{any}", .{req.address}) catch null;

    // Phase 7: IP access control check (first, before rate limiting)
    // Store the result to avoid duplicate checkAccess calls
    var is_whitelisted = false;
    if (ctx.ip_access_control) |ip_control| {
        if (client_ip) |ip| {
            const access_result = ip_control.checkAccess(ip);
            switch (access_result) {
                .blocked => {
                    res.status = 403; // Forbidden
                    res.body =
                        \\{"error":"Forbidden","message":"Your IP address has been blocked."}
                    ;
                    res.headers.add("Content-Type", "application/json");
                    return false;
                },
                .whitelisted => {
                    // Whitelisted IPs bypass rate limiting
                    is_whitelisted = true;
                },
                .allowed => {
                    // Continue to rate limiting
                },
            }
        }
    }

    // Rate limiting check (skip for whitelisted IPs)
    if (ctx.rate_limiter) |rate_limiter| {
        if (!is_whitelisted and !rate_limiter.checkRequest(client_ip)) {
            res.status = 429; // Too Many Requests
            res.body =
                \\{"error":"Too Many Requests","message":"Rate limit exceeded. Please try again later."}
            ;
            // Use pre-formatted rate_limit_window string (optimization: avoids formatting per request)
            res.headers.add("Retry-After", ctx.rate_limit_window_str[0..ctx.rate_limit_window_len]);
            res.headers.add("Content-Type", "application/json");
            return false;
        }

        // Add rate limit headers (skip for whitelisted)
        if (!is_whitelisted) {
            const remaining = rate_limiter.getRemainingTokens(client_ip);
            var remaining_buf: [16]u8 = undefined;
            const remaining_str = std.fmt.bufPrint(&remaining_buf, "{d}", .{remaining}) catch "0";
            res.headers.add("X-RateLimit-Remaining", remaining_str);
        }
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
                    // Add pre-formatted max-age header for preflight caching (optimization)
                    res.headers.add("Access-Control-Max-Age", cors.getMaxAgeStr());
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
                // Execute auth script - Lua side should access authorization header directly
                // via req:header() and perform its own token extraction and validation
                const result = handler.executeScriptWithContext(auth.config.auth_script, "handle_request", req, res) catch {
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

/// Helper function to log HTTP access and record metrics
fn logAccess(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response, duration_us: i64) void {
    // Record metrics if enabled
    if (ctx.metrics) |metrics| {
        metrics.recordRequest(res.status, duration_us, res.body.len);
    }

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

/// Add request ID header to response if enabled
fn addRequestIdHeader(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) void {
    if (!ctx.config.enable_request_id) return;

    // Check if client provided a request ID
    if (req.headers.get(request_id.HEADER_NAME)) |existing| {
        if (request_id.isValid(existing)) {
            res.headers.add(request_id.HEADER_NAME, existing);
            return;
        }
    }

    // Generate a new request ID - use arena allocator to ensure lifetime
    var id_buf: [37]u8 = undefined;
    const generated_id = request_id.generate(&id_buf);

    // Copy to arena to ensure proper lifetime for response
    const arena_id = res.arena.dupe(u8, generated_id) catch return;
    res.headers.add(request_id.HEADER_NAME, arena_id);
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
    // Note: Truncation is handled silently to avoid recursive logging issues
    // The caller should be aware that long fields may be truncated
    return buf[0..j];
}

/// Health check endpoint handler
/// Returns server health status in JSON format
/// Note: Health check does not record metrics to avoid feedback loops
fn healthHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Add request ID header
    addRequestIdHeader(ctx, req, res);

    // Delegate to the modular health handler
    try health_handler.handle(ctx, req, res);
}

/// Prometheus metrics endpoint handler
/// Returns metrics in Prometheus text exposition format
/// Note: Metrics endpoint does not record metrics to avoid feedback loops
fn metricsHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Add request ID header
    addRequestIdHeader(ctx, req, res);

    // Delegate to the modular metrics handler
    try metrics_handler.handle(ctx, req, res);
}

/// Server-Sent Events (SSE) handler
/// Sends a stream of events to the client
fn sseHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
    }

    // Delegate to the modular SSE handler
    try sse_handler.handle(ctx, req, res);
}

/// WebSocket upgrade handler
/// Handles WebSocket upgrade requests and delegates to WebSocketHandler
fn websocketHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Apply middleware (rate limiting, CORS, auth) before accepting WebSocket connection
    if (!applyMiddleware(ctx, req, res)) {
        return;
    }

    // Delegate to the modular WebSocket handler
    try websocket_handler.handle(ctx, req, res);
}

fn serveStatic(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    // Add request ID header
    addRequestIdHeader(ctx, req, res);

    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
    }

    // Delegate to the modular static file handler
    try static_handler.handle(ctx, req, res);
}

fn luaApi(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    // Add request ID header
    addRequestIdHeader(ctx, req, res);

    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) {
        return;
    }

    // Delegate to the modular Lua handler
    try lua_handler.handle(ctx, req, res);
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

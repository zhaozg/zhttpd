//! zhttpd HTTP Request Handlers
//!
//! This module implements the core HTTP request handling logic for zhttpd.
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
//! - Route handlers: Static files, Lua API, GraphQL, WebSocket, SSE
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
const config_mod = @import("../config/config.zig");
const Config = config_mod.Config;
const HandlerMapping = config_mod.HandlerMapping;
const security = @import("../security/security.zig");
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
const KeyValue = lua_mod.KeyValue;
const GraphQLHandler = @import("../graphql/graphql.zig").GraphQLHandler;
const logger_mod = @import("../logger/logger.zig");
const Logger = logger_mod.Logger;
const LogLevel = logger_mod.LogLevel;
const LogFormat = logger_mod.LogFormat;
const FileCache = @import("../cache/file_cache.zig").FileCache;
const middleware = @import("../middleware/middleware.zig");
const RateLimiter = middleware.RateLimiter;
const CorsMiddleware = middleware.CorsMiddleware;
const AuthMiddleware = middleware.AuthMiddleware;
const IpAccessControl = middleware.IpAccessControl;
const IpAccessResult = middleware.IpAccessResult;
const ws_mod = @import("websocket.zig");
const WebSocketHandler = ws_mod.WebSocketHandler;
const WebSocketContext = ws_mod.WebSocketContext;
// Phase 5: Observability
const observability = @import("../observability/observability.zig");
const Metrics = observability.Metrics;
const HealthCheck = observability.health.HealthCheck;
const request_id = observability.request_id;
// Plugins
const db_plugin = @import("../plugins/db/db.zig");
const DbPlugin = db_plugin.DbPlugin;
// Individual handler modules
const static_handler = @import("static_handler.zig");
const lua_handler = @import("lua_handler.zig");
const graphql_handler = @import("graphql_handler.zig");
const health_handler = @import("health_handler.zig");
const metrics_handler = @import("metrics_handler.zig");
const sse_handler = @import("sse_handler.zig");
const websocket_handler = @import("websocket_handler.zig");

/// Application context holding shared state for all request handlers.
///
/// This struct is initialized once during server startup and shared across
/// all worker threads. Thread-safe components (e.g., RateLimiter) use internal
/// mutex protection. Per-request allocations use the response arena allocator.
///
/// ## Lifecycle
/// - Created in `HttpzServer.init()`
/// - Passed to all route handlers via httpz context mechanism
/// - Cleaned up in `HttpzServer.deinit()`
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
    // Phase 5: Observability
    metrics: ?*Metrics = null,
    start_time: i64 = 0,
    // Phase 7: Security
    ip_access_control: ?*IpAccessControl = null,
    // Database plugin
    db_plugin: ?*DbPlugin = null,

    /// WebSocket handler declaration for httpz integration
    /// This enables WebSocket support in httpz.Server
    pub const WebsocketHandler = WebSocketHandler;

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

        // Parse log format
        const log_format: LogFormat = if (std.mem.eql(u8, config.log_format, "json")) .json else .text;

        // Initialize main logger
        var logger = try Logger.initWithFormat(allocator, log_level, config.log_file, log_format);
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

        // Phase 5: Initialize metrics if enabled
        var metrics_ptr: ?*Metrics = null;
        if (config.enable_metrics) {
            metrics_ptr = try allocator.create(Metrics);
            errdefer allocator.destroy(metrics_ptr.?);
            metrics_ptr.?.* = Metrics.init();
        }

        var ctx = AppContext{
            .allocator = allocator,
            .config = config,
            .file_cache = file_cache,
            .logger = logger,
            .access_logger = access_logger,
            .metrics = metrics_ptr,
            .start_time = std.time.timestamp(),
        };

        // Initialize Lua handler if enabled
        if (config.enable_lua) {
            // Create sandbox config from configuration
            const sandbox_config = lua_mod.SandboxConfig{
                .max_instructions = config.lua_max_instructions,
                .enable_sandbox = config.lua_sandbox_enabled,
            };
            ctx.lua_handler = try LuaHandler.initWithConfig(allocator, config.lua_scripts_dir, file_cache, sandbox_config);
            errdefer if (ctx.lua_handler) |*lua| lua.deinit();
            ctx.logger.info("Lua handler initialized with scripts from: {s} (reload: {s}, sandbox: {s}, max_instructions: {})", .{
                config.lua_scripts_dir,
                @tagName(config.reload),
                if (config.lua_sandbox_enabled) "enabled" else "disabled",
                config.lua_max_instructions,
            });
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

        // Phase 7: Initialize IP access control if enabled
        if (config.enable_ip_blacklist) {
            const ip_access_control = try allocator.create(IpAccessControl);
            errdefer allocator.destroy(ip_access_control);
            ip_access_control.* = try IpAccessControl.init(allocator, .{
                .enabled = true,
                .blacklist = config.ip_blacklist,
                .whitelist = config.ip_whitelist,
            });
            ctx.ip_access_control = ip_access_control;
            ctx.logger.info("IP access control initialized (blacklist: {d} entries, whitelist: {d} entries)", .{
                ip_access_control.getBlacklistCount(),
                ip_access_control.getWhitelistCount(),
            });
        }

        // Log WebSocket and SSE status
        if (config.enable_websocket) {
            ctx.logger.info("WebSocket support enabled", .{});
        }
        if (config.enable_sse) {
            ctx.logger.info("Server-Sent Events (SSE) support enabled", .{});
        }

        // Initialize database plugin if enabled
        if (config.enable_db and config.db_uri.len > 0) {
            const plugin = DbPlugin.create(allocator) catch |err| {
                ctx.logger.warn("Failed to create database plugin: {}", .{err});
                // Continue without database - it's optional
                ctx.db_plugin = null;
                return ctx;
            };

            // Build config JSON for plugin initialization
            // Note: We escape special JSON characters in the URI to prevent injection
            var config_buf: [1024]u8 = undefined;
            var uri_buf: [512]u8 = undefined;
            var uri_len: usize = 0;
            for (config.db_uri) |c| {
                if (uri_len >= uri_buf.len - 2) break;
                switch (c) {
                    '"' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = '"';
                        uri_len += 1;
                    },
                    '\\' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                    },
                    '\n' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = 'n';
                        uri_len += 1;
                    },
                    else => {
                        uri_buf[uri_len] = c;
                        uri_len += 1;
                    },
                }
            }
            const db_config_json = std.fmt.bufPrint(&config_buf, "{{\"uri\":\"{s}\",\"pool_size\":{d}}}", .{
                uri_buf[0..uri_len],
                config.db_pool_size,
            }) catch {
                ctx.logger.warn("Failed to format database config", .{});
                allocator.destroy(plugin);
                ctx.db_plugin = null;
                return ctx;
            };

            // Initialize the plugin
            var p = plugin.asPlugin();
            if (p.init(allocator, db_config_json)) {
                ctx.db_plugin = plugin;
                // Set global plugin pointer for Lua access
                db_plugin.setGlobalPlugin(plugin);
                ctx.logger.info("Database plugin initialized: {s} (pool size: {d})", .{ config.db_uri, config.db_pool_size });
            } else {
                ctx.logger.warn("Database plugin initialization failed: {s}", .{plugin.error_message orelse "unknown error"});
                allocator.destroy(plugin);
                ctx.db_plugin = null;
            }
        }

        // Phase 5: Log observability status
        if (config.enable_metrics) {
            ctx.logger.info("Prometheus metrics endpoint: /metrics", .{});
        }
        if (config.enable_health_check) {
            ctx.logger.info("Health check endpoint: /health", .{});
        }
        if (config.enable_request_id) {
            ctx.logger.info("Request ID propagation enabled (X-Request-ID)", .{});
        }
        if (std.mem.eql(u8, config.log_format, "json")) {
            ctx.logger.info("Structured JSON logging enabled", .{});
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
        if (self.ip_access_control) |ip_control| {
            ip_control.deinit();
            self.allocator.destroy(ip_control);
        }
        if (self.db_plugin) |plugin| {
            // Clear global plugin pointer
            db_plugin.setGlobalPlugin(null);
            var p = plugin.asPlugin();
            p.deinit();
            self.allocator.destroy(plugin);
        }
        if (self.metrics) |metrics_ptr| {
            self.allocator.destroy(metrics_ptr);
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
        } else if (std.mem.eql(u8, handler_name, "Handler.GraphQLHandler")) {
            if (!self.context.config.enable_graphql) {
                self.context.logger.warn("Skipping {s} at {s} - graphql feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, graphqlGet, .{});
            router.post(pattern, graphqlPost, .{});
            self.context.logger.debug("Registered GraphQLHandler at {s}", .{pattern});
        } else if (std.mem.eql(u8, handler_name, "Handler.GraphQLPlaygroundHandler")) {
            if (!self.context.config.enable_graphql) {
                self.context.logger.warn("Skipping {s} at {s} - graphql feature is disabled", .{ handler_name, pattern });
                return;
            }
            router.get(pattern, graphqlPlayground, .{});
            self.context.logger.debug("Registered GraphQLPlaygroundHandler at {s}", .{pattern});
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
            // Use actual rate_limit_window config value for Retry-After
            var retry_after_buf: [16]u8 = undefined;
            const retry_after_str = std.fmt.bufPrint(&retry_after_buf, "{d}", .{ctx.config.rate_limit_window}) catch "60";
            res.headers.add("Retry-After", retry_after_str);
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

fn graphqlGet(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
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

    // Delegate to the modular GraphQL handler
    try graphql_handler.handleGet(ctx, req, res);
}

fn graphqlPost(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
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

    // Delegate to the modular GraphQL handler
    try graphql_handler.handlePost(ctx, req, res);
}

/// GraphQL Playground UI handler
fn graphqlPlayground(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
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

    // Delegate to the modular GraphQL Playground handler
    try graphql_handler.handlePlayground(ctx, req, res);
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

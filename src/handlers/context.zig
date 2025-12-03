//! Application Context
//!
//! This module defines the AppContext struct which holds shared state
//! for all request handlers. It is initialized once during server startup
//! and shared across all worker threads.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const Config = config_mod.Config;
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
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
const ws_mod = @import("websocket.zig");
const WebSocketHandler = ws_mod.WebSocketHandler;
// Phase 5: Observability
const observability = @import("../observability/observability.zig");
const Metrics = observability.Metrics;
// Plugins
const db_manager_mod = @import("../plugins/db/manager.zig");
const DbManager = db_manager_mod.DbManager;
// Session management
const session_mod = @import("../session/mod.zig");
const SessionManager = session_mod.SessionManager;

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
    // Database manager (holds multiple named data sources)
    db_manager: ?*DbManager = null,
    // Session manager
    session_manager: ?*SessionManager = null,
    // Cached absolute path for static directory (optimization: avoids realpath syscall per request)
    static_dir_abs: ?[]const u8 = null,
    // Pre-formatted rate limit window string (optimization: avoids formatting on every 429 response)
    rate_limit_window_str: [16]u8 = undefined,
    rate_limit_window_len: usize = 0,

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
        var logger = try logger_mod.initWithFormat(allocator, log_level, config.log_file, log_format);
        errdefer logger.deinit();

        // Initialize access logger if configured
        var access_logger: ?Logger = null;
        if (config.access_log_file) |_| {
            access_logger = try logger_mod.init(allocator, .info, config.access_log_file);
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

        // Cache the absolute path of static directory (optimization: avoids realpath syscall per request)
        ctx.static_dir_abs = std.fs.cwd().realpathAlloc(allocator, config.static_dir) catch |err| blk: {
            logger.warn("Could not cache static directory path (will resolve per request): {}", .{err});
            break :blk null;
        };

        // Initialize Lua handler if enabled
        if (config.enable_lua) {
            // Create sandbox config from configuration
            const sandbox_config = lua_mod.SandboxConfig{
                .max_instructions = config.lua_max_instructions,
                .enable_sandbox = config.lua_sandbox_enabled,
                .lua_path = config.lua_path,
                .lua_cpath = config.lua_cpath,
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
            // Pre-format the rate limit window string (optimization: avoids formatting on every 429 response)
            if (std.fmt.bufPrint(&ctx.rate_limit_window_str, "{d}", .{config.rate_limit_window})) |slice| {
                ctx.rate_limit_window_len = slice.len;
            } else |_| {
                ctx.rate_limit_window_str[0] = '6';
                ctx.rate_limit_window_str[1] = '0';
                ctx.rate_limit_window_len = 2;
            }
            ctx.logger.info("Rate limiter initialized: {d} requests per {d} seconds", .{ config.rate_limit_requests, config.rate_limit_window });
        }

        // Initialize CORS middleware if enabled
        if (config.enable_cors) {
            ctx.cors_middleware = try CorsMiddleware.init(allocator, .{
                .enabled = true,
                .allowed_origins = config.cors_origins,
                .allowed_methods = config.cors_methods,
                .allowed_headers = config.cors_headers,
                .origin_cache_size = config.cors_origin_cache_size,
            });
            errdefer if (ctx.cors_middleware) |*cors| cors.deinit();
            // Set metrics for cache tracking
            if (ctx.cors_middleware) |*cors| {
                if (ctx.metrics) |metrics| {
                    cors.setMetrics(metrics);
                }
            }
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
                .cache_size = config.ip_access_cache_size,
            });
            // Set metrics for cache tracking
            if (ctx.metrics) |metrics| {
                ip_access_control.setMetrics(metrics);
            }
            ctx.ip_access_control = ip_access_control;
            if (ip_access_control.getCacheStats()) |stats| {
                ctx.logger.info("IP access control initialized (blacklist: {d} entries, whitelist: {d} entries, cache: {d})", .{
                    ip_access_control.getBlacklistCount(),
                    ip_access_control.getWhitelistCount(),
                    stats.max_size,
                });
            } else {
                ctx.logger.info("IP access control initialized (blacklist: {d} entries, whitelist: {d} entries, cache: disabled)", .{
                    ip_access_control.getBlacklistCount(),
                    ip_access_control.getWhitelistCount(),
                });
            }
        }

        // Log WebSocket and SSE status
        if (config.enable_websocket) {
            ctx.logger.info("WebSocket support enabled", .{});
        }
        if (config.enable_sse) {
            ctx.logger.info("Server-Sent Events (SSE) support enabled", .{});
        }

        // Initialize database manager if enabled
        if (config.enable_db and config.data_sources.len > 0) {
            // Convert config data sources to the format expected by DbManager
            var ds_configs = allocator.alloc(db_manager_mod.DataSourceConfig, config.data_sources.len) catch {
                ctx.logger.warn("Failed to allocate data source configs", .{});
                ctx.db_manager = null;
                return ctx;
            };
            defer allocator.free(ds_configs);

            for (config.data_sources, 0..) |ds, i| {
                ds_configs[i] = .{
                    .name = ds.name,
                    .uri = ds.uri,
                    .pool_size = ds.pool_size,
                };
            }

            const manager = allocator.create(DbManager) catch {
                ctx.logger.warn("Failed to allocate database manager", .{});
                ctx.db_manager = null;
                return ctx;
            };

            manager.* = DbManager.init(allocator, ds_configs) catch |err| {
                ctx.logger.warn("Failed to initialize database manager: {}", .{err});
                allocator.destroy(manager);
                ctx.db_manager = null;
                return ctx;
            };

            ctx.db_manager = manager;
            // Set global database manager for context module access
            db_manager_mod.setGlobalManager(manager);

            if (manager.count() == 0) {
                ctx.logger.warn("Database manager initialized but no data sources were successfully configured (check logs above for errors)", .{});
            } else {
                ctx.logger.info("Database manager initialized with {d} data source(s)", .{manager.count()});

                // Log each data source
                for (config.data_sources) |ds| {
                    // Only log if the data source was actually initialized
                    if (manager.has(ds.name)) {
                        ctx.logger.info("  - Data source '{s}': {s}", .{ ds.name, ds.uri });
                    }
                }
            }
        } else if (config.enable_db and config.data_sources.len == 0) {
            ctx.logger.warn("Database plugin enabled but no data sources were successfully configured (set db_uri or configure data_sources in config)", .{});
        }

        // Initialize session manager if enabled
        if (config.enable_session) {
            const session_manager = allocator.create(SessionManager) catch {
                ctx.logger.warn("Failed to allocate session manager", .{});
                return ctx;
            };

            session_manager.* = SessionManager.init(allocator, .{
                .max_sessions = config.session_max_size,
                .default_ttl = config.session_default_ttl,
                .cookie_name = config.session_cookie_name,
                .cookie_secure = config.session_cookie_secure,
                .cookie_http_only = config.session_cookie_http_only,
            }) catch |err| {
                ctx.logger.warn("Failed to initialize session manager: {}", .{err});
                allocator.destroy(session_manager);
                return ctx;
            };

            ctx.session_manager = session_manager;
            // Set global session manager for Lua context module access
            session_mod.setGlobalManager(session_manager);
            ctx.logger.info("Session manager initialized (max: {d}, ttl: {d}s, cookie: {s})", .{
                config.session_max_size,
                config.session_default_ttl,
                config.session_cookie_name,
            });
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
        if (self.rate_limiter) |rate_limiter| {
            rate_limiter.deinit();
            self.allocator.destroy(rate_limiter);
        }
        if (self.cors_middleware) |*cors| {
            cors.deinit();
        }
        if (self.ip_access_control) |ip_control| {
            ip_control.deinit();
            self.allocator.destroy(ip_control);
        }
        if (self.db_manager) |manager| {
            // Clear global manager pointer
            db_manager_mod.setGlobalManager(null);
            manager.deinit();
            self.allocator.destroy(manager);
        }
        if (self.session_manager) |session_manager| {
            // Clear global session manager pointer
            session_mod.setGlobalManager(null);
            session_manager.deinit();
            self.allocator.destroy(session_manager);
        }
        if (self.metrics) |metrics_ptr| {
            self.allocator.destroy(metrics_ptr);
        }
        // Free cached static directory path
        if (self.static_dir_abs) |static_dir_abs| {
            self.allocator.free(static_dir_abs);
        }
        self.file_cache.deinit();
        self.allocator.destroy(self.file_cache);
        self.logger.deinit();
        if (self.access_logger) |*al| {
            al.deinit();
        }
    }
};

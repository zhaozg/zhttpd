const std = @import("std");
const yaml = @import("yaml");

// Default configuration values
pub const DEFAULT_MAX_CONNECTIONS: u32 = 512;
pub const DEFAULT_REQUEST_BUFFER_SIZE: usize = 65536; // 64KB
pub const DEFAULT_MAX_CACHE_FILE_SIZE: usize = 1024 * 1024; // 1MB

pub const ReloadMode = enum {
    never, // Cache file in memory, read once and use continuously
    auto, // Detect file modification and re-read if modified, otherwise use cache
    force, // Re-read file every time

    pub fn fromString(s: []const u8) ReloadMode {
        if (std.ascii.eqlIgnoreCase(s, "never")) return .never;
        if (std.ascii.eqlIgnoreCase(s, "force")) return .force;
        return .auto; // default
    }
};

/// Handler mapping from URL pattern to handler name
pub const HandlerMapping = struct {
    pattern: []const u8,
    handler: []const u8,
};

pub const Config = struct {
    host: []const u8,
    port: u16,
    static_dir: []const u8,
    lua_scripts_dir: []const u8,
    security_headers: bool,
    max_body_size: usize,
    timeout_seconds: u32,
    thread_pool_size: u32,
    max_connections: u32, // Maximum concurrent connections
    request_buffer_size: usize, // Buffer size for request/response
    enable_lua: bool,
    enable_graphql: bool,
    graphql_endpoint: []const u8,
    log_level: []const u8,
    log_file: ?[]const u8,
    access_log_file: ?[]const u8,
    reload: ReloadMode,
    max_cache_file_size: usize, // Maximum file size to cache in bytes
    enable_etag: bool, // Enable ETag support for static files
    // Phase 3: Advanced httpz features
    enable_websocket: bool, // Enable WebSocket support
    enable_sse: bool, // Enable Server-Sent Events support
    // Rate limiting configuration
    enable_rate_limit: bool,
    rate_limit_requests: u32, // Max requests per window
    rate_limit_window: u32, // Window in seconds
    // CORS configuration
    enable_cors: bool,
    cors_origins: []const u8, // Allowed origins (* for any)
    cors_methods: []const u8, // Allowed methods
    cors_headers: []const u8, // Allowed headers
    // Authentication configuration (delegated to Lua)
    enable_auth: bool,
    auth_script: []const u8, // Lua script name for auth validation
    auth_protected_paths: []const u8, // Paths requiring auth
    auth_public_paths: []const u8, // Always public paths
    // Lua sandbox configuration (safe defaults)
    lua_sandbox_enabled: bool, // Enable Lua sandbox (default: true)
    lua_max_instructions: u32, // Max Lua instructions per execution (0 = unlimited, default: 100000)
    // Phase 5: Observability configuration
    enable_metrics: bool, // Enable Prometheus metrics at /metrics
    enable_health_check: bool, // Enable health check at /health
    enable_request_id: bool, // Enable X-Request-ID propagation
    log_format: []const u8, // Log format: "text" or "json"
    // Phase 7: Security enhancements
    enable_ip_blacklist: bool, // Enable IP blacklist/whitelist
    ip_blacklist: []const u8, // Comma-separated list of blocked IPs/CIDRs
    ip_whitelist: []const u8, // Comma-separated list of whitelisted IPs/CIDRs
    // Handler mappings from URL pattern to handler name
    handlers: []HandlerMapping,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Config) void {
        self.allocator.free(self.host);
        self.allocator.free(self.static_dir);
        self.allocator.free(self.lua_scripts_dir);
        self.allocator.free(self.graphql_endpoint);
        self.allocator.free(self.log_level);
        if (self.log_file) |lf| {
            self.allocator.free(lf);
        }
        if (self.access_log_file) |alf| {
            self.allocator.free(alf);
        }
        self.allocator.free(self.cors_origins);
        self.allocator.free(self.cors_methods);
        self.allocator.free(self.cors_headers);
        self.allocator.free(self.auth_script);
        self.allocator.free(self.auth_protected_paths);
        self.allocator.free(self.auth_public_paths);
        self.allocator.free(self.log_format);
        self.allocator.free(self.ip_blacklist);
        self.allocator.free(self.ip_whitelist);
        // Free handler mappings
        for (self.handlers) |mapping| {
            self.allocator.free(mapping.pattern);
            self.allocator.free(mapping.handler);
        }
        self.allocator.free(self.handlers);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Try to load config file, fallback to defaults
    // Note: Using std.debug.print here since logger is not yet initialized
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Config file '{s}' not found: {}\n", .{ path, err });
        std.debug.print("Using default configuration\n", .{});
        return getDefaultConfig(allocator);
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Determine format based on file extension or content
    const is_yaml = std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml");

    if (is_yaml) {
        return parseYaml(allocator, content) catch |err| {
            std.debug.print("YAML parse error in '{s}': {}\n", .{ path, err });
            std.debug.print("Using default configuration\n", .{});
            return getDefaultConfig(allocator);
        };
    } else {
        return parseJson(allocator, content) catch |err| {
            std.debug.print("JSON parse error in '{s}': {}\n", .{ path, err });
            std.debug.print("Using default configuration\n", .{});
            return getDefaultConfig(allocator);
        };
    }
}

fn parseJson(allocator: std.mem.Allocator, content: []const u8) !Config {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    return Config{
        .host = try allocator.dupe(u8, root.get("host").?.string),
        .port = @intCast(root.get("port").?.integer),
        .static_dir = try allocator.dupe(u8, root.get("static_dir").?.string),
        .lua_scripts_dir = try allocator.dupe(u8, root.get("lua_scripts_dir").?.string),
        .security_headers = root.get("security_headers").?.bool,
        .max_body_size = @intCast(root.get("max_body_size").?.integer),
        .timeout_seconds = @intCast(root.get("timeout_seconds").?.integer),
        .thread_pool_size = @intCast(root.get("thread_pool_size").?.integer),
        .max_connections = if (root.get("max_connections")) |mc| @intCast(mc.integer) else DEFAULT_MAX_CONNECTIONS,
        .request_buffer_size = if (root.get("request_buffer_size")) |rbs| @intCast(rbs.integer) else DEFAULT_REQUEST_BUFFER_SIZE,
        .enable_lua = root.get("enable_lua").?.bool,
        .enable_graphql = root.get("enable_graphql").?.bool,
        .graphql_endpoint = try allocator.dupe(u8, root.get("graphql_endpoint").?.string),
        .log_level = if (root.get("log_level")) |ll| try allocator.dupe(u8, ll.string) else try allocator.dupe(u8, "info"),
        .log_file = if (root.get("log_file")) |lf| try allocator.dupe(u8, lf.string) else null,
        .access_log_file = if (root.get("access_log_file")) |alf| try allocator.dupe(u8, alf.string) else null,
        .reload = if (root.get("reload")) |r| ReloadMode.fromString(r.string) else .auto,
        .max_cache_file_size = if (root.get("max_cache_file_size")) |mcfs| @intCast(mcfs.integer) else DEFAULT_MAX_CACHE_FILE_SIZE,
        .enable_etag = if (root.get("enable_etag")) |ee| ee.bool else true, // Default enabled
        // Phase 3: Advanced httpz features
        .enable_websocket = if (root.get("enable_websocket")) |ew| ew.bool else false,
        .enable_sse = if (root.get("enable_sse")) |es| es.bool else false,
        // Rate limiting
        .enable_rate_limit = if (root.get("enable_rate_limit")) |erl| erl.bool else false,
        .rate_limit_requests = if (root.get("rate_limit_requests")) |rlr| @intCast(rlr.integer) else 100,
        .rate_limit_window = if (root.get("rate_limit_window")) |rlw| @intCast(rlw.integer) else 60,
        // CORS
        .enable_cors = if (root.get("enable_cors")) |ec| ec.bool else false,
        .cors_origins = if (root.get("cors_origins")) |co| try allocator.dupe(u8, co.string) else try allocator.dupe(u8, "*"),
        .cors_methods = if (root.get("cors_methods")) |cm| try allocator.dupe(u8, cm.string) else try allocator.dupe(u8, "GET, POST, PUT, DELETE, OPTIONS"),
        .cors_headers = if (root.get("cors_headers")) |ch| try allocator.dupe(u8, ch.string) else try allocator.dupe(u8, "Content-Type, Authorization"),
        // Authentication
        .enable_auth = if (root.get("enable_auth")) |ea| ea.bool else false,
        .auth_script = if (root.get("auth_script")) |as_val| try allocator.dupe(u8, as_val.string) else try allocator.dupe(u8, "auth"),
        .auth_protected_paths = if (root.get("auth_protected_paths")) |app| try allocator.dupe(u8, app.string) else try allocator.dupe(u8, "/api/*"),
        .auth_public_paths = if (root.get("auth_public_paths")) |apu| try allocator.dupe(u8, apu.string) else try allocator.dupe(u8, "/api/login, /api/register"),
        // Lua sandbox configuration (safe defaults)
        .lua_sandbox_enabled = if (root.get("lua_sandbox_enabled")) |lse| lse.bool else true,
        .lua_max_instructions = if (root.get("lua_max_instructions")) |lmi| @intCast(lmi.integer) else 100_000,
        // Phase 5: Observability configuration
        .enable_metrics = if (root.get("enable_metrics")) |em| em.bool else true, // Default enabled
        .enable_health_check = if (root.get("enable_health_check")) |ehc| ehc.bool else true, // Default enabled
        .enable_request_id = if (root.get("enable_request_id")) |eri| eri.bool else true, // Default enabled
        .log_format = if (root.get("log_format")) |lf_val| try allocator.dupe(u8, lf_val.string) else try allocator.dupe(u8, "text"),
        // Phase 7: Security enhancements
        .enable_ip_blacklist = if (root.get("enable_ip_blacklist")) |eib| eib.bool else false,
        .ip_blacklist = if (root.get("ip_blacklist")) |ibl| try allocator.dupe(u8, ibl.string) else try allocator.dupe(u8, ""),
        .ip_whitelist = if (root.get("ip_whitelist")) |iwl| try allocator.dupe(u8, iwl.string) else try allocator.dupe(u8, ""),
        // Handler mappings - parse from JSON object
        .handlers = try parseHandlersFromJson(allocator, root.get("handlers")),
        .allocator = allocator,
    };
}

/// Parse handlers mapping from JSON object
fn parseHandlersFromJson(allocator: std.mem.Allocator, handlers_value: ?std.json.Value) ![]HandlerMapping {
    if (handlers_value) |handlers_obj| {
        if (handlers_obj == .object) {
            const obj = handlers_obj.object;
            var mappings = try allocator.alloc(HandlerMapping, obj.count());
            errdefer allocator.free(mappings);
            var i: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    mappings[i] = .{
                        .pattern = try allocator.dupe(u8, entry.key_ptr.*),
                        .handler = try allocator.dupe(u8, entry.value_ptr.string),
                    };
                    i += 1;
                }
            }
            // Shrink to actual size if some entries were skipped
            if (i < mappings.len) {
                mappings = try allocator.realloc(mappings, i);
            }
            return mappings;
        }
    }
    // Return default handlers if not specified
    return try getDefaultHandlers(allocator);
}

/// Get default handler mappings
pub fn getDefaultHandlers(allocator: std.mem.Allocator) ![]HandlerMapping {
    // Default handler configuration - order matters (more specific first)
    const default_mappings = [_]struct { pattern: []const u8, handler: []const u8 }{
        .{ .pattern = "/health", .handler = "Handler.HealthCheckHandler" },
        .{ .pattern = "/metrics", .handler = "Handler.MetricsHandler" },
        .{ .pattern = "/ws", .handler = "Handler.WebSocketHandler" },
        .{ .pattern = "/graphql/playground", .handler = "Handler.GraphQLPlaygroundHandler" },
        .{ .pattern = "/graphql/ws", .handler = "Handler.WebSocketHandler" },
        .{ .pattern = "/graphql", .handler = "Handler.GraphQLHandler" },
        .{ .pattern = "/api/*", .handler = "Handler.LuaHandler" },
        .{ .pattern = "/events", .handler = "Handler.SSEHandler" },
        .{ .pattern = "/*", .handler = "Handler.StaticFileHandler" },
    };

    var mappings = try allocator.alloc(HandlerMapping, default_mappings.len);
    errdefer allocator.free(mappings);

    for (default_mappings, 0..) |dm, i| {
        mappings[i] = .{
            .pattern = try allocator.dupe(u8, dm.pattern),
            .handler = try allocator.dupe(u8, dm.handler),
        };
    }
    return mappings;
}

pub fn getDefaultConfig(allocator: std.mem.Allocator) !Config {
    return Config{
        .host = try allocator.dupe(u8, "0.0.0.0"),
        .port = 8080,
        .static_dir = try allocator.dupe(u8, "./examples/static"),
        .lua_scripts_dir = try allocator.dupe(u8, "./examples/lua"),
        .security_headers = true,
        .max_body_size = 1024 * 1024 * 10, // 10MB
        .timeout_seconds = 30,
        .thread_pool_size = 4,
        .max_connections = DEFAULT_MAX_CONNECTIONS,
        .request_buffer_size = DEFAULT_REQUEST_BUFFER_SIZE,
        .enable_lua = true,
        .enable_graphql = true,
        .graphql_endpoint = try allocator.dupe(u8, "/graphql"),
        .log_level = try allocator.dupe(u8, "info"),
        .log_file = null,
        .access_log_file = null,
        .reload = .auto, // Default to auto reload mode
        .max_cache_file_size = DEFAULT_MAX_CACHE_FILE_SIZE,
        .enable_etag = true, // Default enabled
        // Phase 3: Advanced httpz features (disabled by default)
        .enable_websocket = false,
        .enable_sse = false,
        .enable_rate_limit = false,
        .rate_limit_requests = 100,
        .rate_limit_window = 60,
        .enable_cors = false,
        .cors_origins = try allocator.dupe(u8, "*"),
        .cors_methods = try allocator.dupe(u8, "GET, POST, PUT, DELETE, OPTIONS"),
        .cors_headers = try allocator.dupe(u8, "Content-Type, Authorization"),
        .enable_auth = false,
        .auth_script = try allocator.dupe(u8, "auth"),
        .auth_protected_paths = try allocator.dupe(u8, "/api/*"),
        .auth_public_paths = try allocator.dupe(u8, "/api/login, /api/register"),
        // Lua sandbox configuration (safe defaults)
        .lua_sandbox_enabled = true,
        .lua_max_instructions = 100_000,
        // Phase 5: Observability configuration (enabled by default)
        .enable_metrics = true,
        .enable_health_check = true,
        .enable_request_id = true,
        .log_format = try allocator.dupe(u8, "text"),
        // Phase 7: Security enhancements (disabled by default)
        .enable_ip_blacklist = false,
        .ip_blacklist = try allocator.dupe(u8, ""),
        .ip_whitelist = try allocator.dupe(u8, ""),
        // Default handler mappings
        .handlers = try getDefaultHandlers(allocator),
        .allocator = allocator,
    };
}

/// YAML configuration structure for typed parsing
/// All fields are optional with default values to match getDefaultConfig behavior
const YamlConfig = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
    static_dir: ?[]const u8 = null,
    lua_scripts_dir: ?[]const u8 = null,
    security_headers: ?bool = null,
    max_body_size: ?usize = null,
    timeout_seconds: ?u32 = null,
    thread_pool_size: ?u32 = null,
    max_connections: ?u32 = null,
    request_buffer_size: ?usize = null,
    enable_lua: ?bool = null,
    enable_graphql: ?bool = null,
    graphql_endpoint: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    access_log_file: ?[]const u8 = null,
    reload: ?[]const u8 = null,
    max_cache_file_size: ?usize = null,
    enable_etag: ?bool = null,
    // Phase 3: Advanced httpz features
    enable_websocket: ?bool = null,
    enable_sse: ?bool = null,
    enable_rate_limit: ?bool = null,
    rate_limit_requests: ?u32 = null,
    rate_limit_window: ?u32 = null,
    enable_cors: ?bool = null,
    cors_origins: ?[]const u8 = null,
    cors_methods: ?[]const u8 = null,
    cors_headers: ?[]const u8 = null,
    enable_auth: ?bool = null,
    auth_script: ?[]const u8 = null,
    auth_protected_paths: ?[]const u8 = null,
    auth_public_paths: ?[]const u8 = null,
    // Lua sandbox configuration
    lua_sandbox_enabled: ?bool = null,
    lua_max_instructions: ?u32 = null,
    // Phase 5: Observability configuration
    enable_metrics: ?bool = null,
    enable_health_check: ?bool = null,
    enable_request_id: ?bool = null,
    log_format: ?[]const u8 = null,
    // Phase 7: Security enhancements
    enable_ip_blacklist: ?bool = null,
    ip_blacklist: ?[]const u8 = null,
    ip_whitelist: ?[]const u8 = null,
};

/// Parse YAML content using zig-yaml library
fn parseYaml(allocator: std.mem.Allocator, content: []const u8) !Config {
    // Use arena allocator for YAML parsing intermediate results
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var y: yaml.Yaml = .{ .source = content };
    defer y.deinit(arena.allocator());

    y.load(arena.allocator()) catch |err| switch (err) {
        error.ParseFailure => {
            if (y.parse_errors.errorMessageCount() > 0) {
                y.parse_errors.renderToStdErr(.{ .ttyconf = .no_color });
            }
            return error.ParseFailure;
        },
        else => return err,
    };

    const parsed = try y.parse(arena.allocator(), YamlConfig);

    // Convert parsed YAML to Config with proper memory ownership
    return Config{
        .host = try allocator.dupe(u8, parsed.host orelse "0.0.0.0"),
        .port = parsed.port orelse 8080,
        .static_dir = try allocator.dupe(u8, parsed.static_dir orelse "./examples/static"),
        .lua_scripts_dir = try allocator.dupe(u8, parsed.lua_scripts_dir orelse "./examples/lua"),
        .security_headers = parsed.security_headers orelse true,
        .max_body_size = parsed.max_body_size orelse (1024 * 1024 * 10), // 10MB
        .timeout_seconds = parsed.timeout_seconds orelse 30,
        .thread_pool_size = parsed.thread_pool_size orelse 4,
        .max_connections = parsed.max_connections orelse DEFAULT_MAX_CONNECTIONS,
        .request_buffer_size = parsed.request_buffer_size orelse DEFAULT_REQUEST_BUFFER_SIZE,
        .enable_lua = parsed.enable_lua orelse true,
        .enable_graphql = parsed.enable_graphql orelse true,
        .graphql_endpoint = try allocator.dupe(u8, parsed.graphql_endpoint orelse "/graphql"),
        .log_level = try allocator.dupe(u8, parsed.log_level orelse "info"),
        .log_file = if (parsed.log_file) |lf| try allocator.dupe(u8, lf) else null,
        .access_log_file = if (parsed.access_log_file) |alf| try allocator.dupe(u8, alf) else null,
        .reload = if (parsed.reload) |r| ReloadMode.fromString(r) else .auto,
        .max_cache_file_size = parsed.max_cache_file_size orelse DEFAULT_MAX_CACHE_FILE_SIZE,
        .enable_etag = parsed.enable_etag orelse true,
        // Phase 3: Advanced httpz features
        .enable_websocket = parsed.enable_websocket orelse false,
        .enable_sse = parsed.enable_sse orelse false,
        .enable_rate_limit = parsed.enable_rate_limit orelse false,
        .rate_limit_requests = parsed.rate_limit_requests orelse 100,
        .rate_limit_window = parsed.rate_limit_window orelse 60,
        .enable_cors = parsed.enable_cors orelse false,
        .cors_origins = try allocator.dupe(u8, parsed.cors_origins orelse "*"),
        .cors_methods = try allocator.dupe(u8, parsed.cors_methods orelse "GET, POST, PUT, DELETE, OPTIONS"),
        .cors_headers = try allocator.dupe(u8, parsed.cors_headers orelse "Content-Type, Authorization"),
        .enable_auth = parsed.enable_auth orelse false,
        .auth_script = try allocator.dupe(u8, parsed.auth_script orelse "auth"),
        .auth_protected_paths = try allocator.dupe(u8, parsed.auth_protected_paths orelse "/api/*"),
        .auth_public_paths = try allocator.dupe(u8, parsed.auth_public_paths orelse "/api/login, /api/register"),
        // Lua sandbox configuration
        .lua_sandbox_enabled = parsed.lua_sandbox_enabled orelse true,
        .lua_max_instructions = parsed.lua_max_instructions orelse 100_000,
        // Phase 5: Observability configuration
        .enable_metrics = parsed.enable_metrics orelse true,
        .enable_health_check = parsed.enable_health_check orelse true,
        .enable_request_id = parsed.enable_request_id orelse true,
        .log_format = try allocator.dupe(u8, parsed.log_format orelse "text"),
        // Phase 7: Security enhancements
        .enable_ip_blacklist = parsed.enable_ip_blacklist orelse false,
        .ip_blacklist = try allocator.dupe(u8, parsed.ip_blacklist orelse ""),
        .ip_whitelist = try allocator.dupe(u8, parsed.ip_whitelist orelse ""),
        // Handler mappings - parse manually from raw YAML since zig-yaml doesn't support maps well
        .handlers = try parseHandlersFromYaml(allocator, &y),
        .allocator = allocator,
    };
}

/// Parse handlers mapping from YAML document
fn parseHandlersFromYaml(allocator: std.mem.Allocator, y: *yaml.Yaml) ![]HandlerMapping {
    // Try to find the handlers section in the document
    if (y.docs.items.len > 0) {
        const doc = y.docs.items[0];
        if (doc.asMap()) |doc_map| {
            if (doc_map.get("handlers")) |handlers_val| {
                if (handlers_val.asMap()) |handlers_map| {
                    var mappings = try allocator.alloc(HandlerMapping, handlers_map.count());
                    errdefer allocator.free(mappings);
                    var count: usize = 0;
                    const keys = handlers_map.keys();
                    const values = handlers_map.values();
                    for (keys, values) |pattern, handler_value| {
                        const handler_name = handler_value.asScalar() orelse continue;
                        mappings[count] = .{
                            .pattern = try allocator.dupe(u8, pattern),
                            .handler = try allocator.dupe(u8, handler_name),
                        };
                        count += 1;
                    }
                    // Shrink to actual size if some entries were skipped
                    if (count < mappings.len) {
                        // Free unused entries
                        for (mappings[count..]) |m| {
                            allocator.free(m.pattern);
                            allocator.free(m.handler);
                        }
                        mappings = try allocator.realloc(mappings, count);
                    }
                    return mappings;
                }
            }
        }
    }
    // Return default handlers if not specified
    return try getDefaultHandlers(allocator);
}

test "config loading with defaults" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cfg = try getDefaultConfig(allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("0.0.0.0", cfg.host);
    try testing.expect(cfg.port == 8080);
    try testing.expect(cfg.security_headers == true);
    // Phase 5: Verify observability defaults
    try testing.expect(cfg.enable_metrics == true);
    try testing.expect(cfg.enable_health_check == true);
    try testing.expect(cfg.enable_request_id == true);
    try testing.expectEqualStrings("text", cfg.log_format);
}

test "yaml config parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const yaml_content =
        \\host: "127.0.0.1"
        \\port: 9090
        \\static_dir: "./public"
        \\lua_scripts_dir: "./scripts"
        \\security_headers: false
        \\max_body_size: 5242880  # 5MB
        \\timeout_seconds: 60
        \\thread_pool_size: 8
        \\enable_lua: true
        \\enable_graphql: false
        \\graphql_endpoint: "/gql"
        \\log_level: "debug"
    ;

    const cfg = try parseYaml(allocator, yaml_content);
    defer cfg.deinit();

    try testing.expectEqualStrings("127.0.0.1", cfg.host);
    try testing.expect(cfg.port == 9090);
    try testing.expectEqualStrings("./public", cfg.static_dir);
    try testing.expect(cfg.security_headers == false);
    try testing.expect(cfg.max_body_size == 5242880);
    try testing.expect(cfg.timeout_seconds == 60);
    try testing.expect(cfg.thread_pool_size == 8);
    try testing.expect(cfg.enable_lua == true);
    try testing.expect(cfg.enable_graphql == false);
    try testing.expectEqualStrings("/gql", cfg.graphql_endpoint);
    try testing.expectEqualStrings("debug", cfg.log_level);
    // Default handlers should be present when no handlers section is specified
    try testing.expect(cfg.handlers.len > 0);
}

test "yaml config with custom handlers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const yaml_content =
        \\host: "0.0.0.0"
        \\port: 8080
        \\static_dir: "./static"
        \\lua_scripts_dir: "./lua"
        \\handlers:
        \\  /api/*: Handler.LuaHandler
        \\  /*: Handler.StaticFileHandler
    ;

    const cfg = try parseYaml(allocator, yaml_content);
    defer cfg.deinit();

    // Should have 2 custom handlers
    try testing.expect(cfg.handlers.len == 2);

    // Check first handler
    try testing.expectEqualStrings("/api/*", cfg.handlers[0].pattern);
    try testing.expectEqualStrings("Handler.LuaHandler", cfg.handlers[0].handler);

    // Check second handler
    try testing.expectEqualStrings("/*", cfg.handlers[1].pattern);
    try testing.expectEqualStrings("Handler.StaticFileHandler", cfg.handlers[1].handler);
}

test "default handlers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const handlers = try getDefaultHandlers(allocator);
    defer {
        for (handlers) |m| {
            allocator.free(m.pattern);
            allocator.free(m.handler);
        }
        allocator.free(handlers);
    }

    // Verify default handlers are created
    try testing.expect(handlers.len > 0);

    // Verify some expected defaults exist
    var has_static = false;
    var has_health = false;
    for (handlers) |h| {
        if (std.mem.eql(u8, h.handler, "Handler.StaticFileHandler")) has_static = true;
        if (std.mem.eql(u8, h.handler, "Handler.HealthCheckHandler")) has_health = true;
    }
    try testing.expect(has_static);
    try testing.expect(has_health);
}

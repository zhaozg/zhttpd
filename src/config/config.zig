const std = @import("std");

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
        .allocator = allocator,
    };
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
        .allocator = allocator,
    };
}

/// Parse boolean value from YAML
/// Accepts: true/false, yes/no, 1/0 (case-insensitive)
fn parseBool(value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "1")) return true;
    return false;
}

/// Simple YAML parser for basic key-value config
/// Supports: string, integer values, and boolean values (true/false, yes/no, 1/0)
/// Comments starting with # are supported
fn parseYaml(allocator: std.mem.Allocator, content: []const u8) !Config {
    // Start with default config (all strings are heap-allocated)
    var config = try getDefaultConfig(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Find the colon separator
        const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        if (colon_pos == 0) continue;

        const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
        var value_part = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");

        // Remove inline comments
        if (std.mem.indexOfScalar(u8, value_part, '#')) |comment_pos| {
            value_part = std.mem.trim(u8, value_part[0..comment_pos], " \t");
        }

        // Remove quotes if present
        const value = if (value_part.len >= 2 and
            ((value_part[0] == '"' and value_part[value_part.len - 1] == '"') or
                (value_part[0] == '\'' and value_part[value_part.len - 1] == '\'')))
            value_part[1 .. value_part.len - 1]
        else
            value_part;

        // Parse the value based on the key
        if (std.mem.eql(u8, key, "host")) {
            allocator.free(config.host); // Safe: allocated by getDefaultConfig
            config.host = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "port")) {
            config.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "static_dir")) {
            allocator.free(config.static_dir);
            config.static_dir = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "lua_scripts_dir")) {
            allocator.free(config.lua_scripts_dir);
            config.lua_scripts_dir = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "security_headers")) {
            config.security_headers = parseBool(value);
        } else if (std.mem.eql(u8, key, "max_body_size")) {
            config.max_body_size = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "timeout_seconds")) {
            config.timeout_seconds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "thread_pool_size")) {
            config.thread_pool_size = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "enable_lua")) {
            config.enable_lua = parseBool(value);
        } else if (std.mem.eql(u8, key, "enable_graphql")) {
            config.enable_graphql = parseBool(value);
        } else if (std.mem.eql(u8, key, "graphql_endpoint")) {
            allocator.free(config.graphql_endpoint);
            config.graphql_endpoint = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "log_level")) {
            allocator.free(config.log_level);
            config.log_level = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "log_file")) {
            if (config.log_file) |lf| allocator.free(lf);
            config.log_file = if (value.len > 0) try allocator.dupe(u8, value) else null;
        } else if (std.mem.eql(u8, key, "access_log_file")) {
            if (config.access_log_file) |alf| allocator.free(alf);
            config.access_log_file = if (value.len > 0) try allocator.dupe(u8, value) else null;
        } else if (std.mem.eql(u8, key, "reload")) {
            config.reload = ReloadMode.fromString(value);
        } else if (std.mem.eql(u8, key, "max_cache_file_size")) {
            config.max_cache_file_size = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "enable_etag")) {
            config.enable_etag = parseBool(value);
        } else if (std.mem.eql(u8, key, "max_connections")) {
            config.max_connections = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "request_buffer_size")) {
            config.request_buffer_size = try std.fmt.parseInt(usize, value, 10);
        }
        // Phase 3: Advanced httpz features
        else if (std.mem.eql(u8, key, "enable_websocket")) {
            config.enable_websocket = parseBool(value);
        } else if (std.mem.eql(u8, key, "enable_sse")) {
            config.enable_sse = parseBool(value);
        } else if (std.mem.eql(u8, key, "enable_rate_limit")) {
            config.enable_rate_limit = parseBool(value);
        } else if (std.mem.eql(u8, key, "rate_limit_requests")) {
            config.rate_limit_requests = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "rate_limit_window")) {
            config.rate_limit_window = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "enable_cors")) {
            config.enable_cors = parseBool(value);
        } else if (std.mem.eql(u8, key, "cors_origins")) {
            allocator.free(config.cors_origins);
            config.cors_origins = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "cors_methods")) {
            allocator.free(config.cors_methods);
            config.cors_methods = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "cors_headers")) {
            allocator.free(config.cors_headers);
            config.cors_headers = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "enable_auth")) {
            config.enable_auth = parseBool(value);
        } else if (std.mem.eql(u8, key, "auth_script")) {
            allocator.free(config.auth_script);
            config.auth_script = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "auth_protected_paths")) {
            allocator.free(config.auth_protected_paths);
            config.auth_protected_paths = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "auth_public_paths")) {
            allocator.free(config.auth_public_paths);
            config.auth_public_paths = try allocator.dupe(u8, value);
        }
        // Lua sandbox configuration
        else if (std.mem.eql(u8, key, "lua_sandbox_enabled")) {
            config.lua_sandbox_enabled = parseBool(value);
        } else if (std.mem.eql(u8, key, "lua_max_instructions")) {
            config.lua_max_instructions = try std.fmt.parseInt(u32, value, 10);
        }
        // Phase 5: Observability configuration
        else if (std.mem.eql(u8, key, "enable_metrics")) {
            config.enable_metrics = parseBool(value);
        } else if (std.mem.eql(u8, key, "enable_health_check")) {
            config.enable_health_check = parseBool(value);
        } else if (std.mem.eql(u8, key, "enable_request_id")) {
            config.enable_request_id = parseBool(value);
        } else if (std.mem.eql(u8, key, "log_format")) {
            allocator.free(config.log_format);
            config.log_format = try allocator.dupe(u8, value);
        }
        // Phase 7: Security enhancements
        else if (std.mem.eql(u8, key, "enable_ip_blacklist")) {
            config.enable_ip_blacklist = parseBool(value);
        } else if (std.mem.eql(u8, key, "ip_blacklist")) {
            allocator.free(config.ip_blacklist);
            config.ip_blacklist = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "ip_whitelist")) {
            allocator.free(config.ip_whitelist);
            config.ip_whitelist = try allocator.dupe(u8, value);
        }
    }

    return config;
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
}

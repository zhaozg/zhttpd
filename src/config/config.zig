const std = @import("std");

pub const Config = struct {
    host: []const u8,
    port: u16,
    static_dir: []const u8,
    lua_scripts_dir: []const u8,
    security_headers: bool,
    max_body_size: usize,
    timeout_seconds: u32,
    thread_pool_size: u32,
    enable_lua: bool,
    enable_graphql: bool,
    graphql_endpoint: []const u8,
    log_level: []const u8,
    log_file: ?[]const u8,
    access_log_file: ?[]const u8,
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
        .enable_lua = root.get("enable_lua").?.bool,
        .enable_graphql = root.get("enable_graphql").?.bool,
        .graphql_endpoint = try allocator.dupe(u8, root.get("graphql_endpoint").?.string),
        .log_level = if (root.get("log_level")) |ll| try allocator.dupe(u8, ll.string) else try allocator.dupe(u8, "info"),
        .log_file = if (root.get("log_file")) |lf| try allocator.dupe(u8, lf.string) else null,
        .access_log_file = if (root.get("access_log_file")) |alf| try allocator.dupe(u8, alf.string) else null,
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
        .enable_lua = true,
        .enable_graphql = true,
        .graphql_endpoint = try allocator.dupe(u8, "/graphql"),
        .log_level = try allocator.dupe(u8, "info"),
        .log_file = null,
        .access_log_file = null,
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

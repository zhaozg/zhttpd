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
    allocator: std.mem.Allocator,

    pub fn deinit(self: Config) void {
        self.allocator.free(self.host);
        self.allocator.free(self.static_dir);
        self.allocator.free(self.lua_scripts_dir);
        self.allocator.free(self.graphql_endpoint);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    // Try to load config file, fallback to defaults
    const file = std.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("Config file not found, using defaults\n", .{});
        return getDefaultConfig(allocator);
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parseJson(allocator, content) catch getDefaultConfig(allocator);
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
        .allocator = allocator,
    };
}

fn getDefaultConfig(allocator: std.mem.Allocator) !Config {
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
        .allocator = allocator,
    };
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

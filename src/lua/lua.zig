const std = @import("std");
const ziglua = @import("ziglua");
const FileCache = @import("../cache/file_cache.zig").FileCache;

// Lua integration module
// This module provides integration with Lua for dynamic content handling
// Based on ziglua: https://github.com/natecraddock/ziglua
//
// Thread Safety:
// Each request gets its own Lua state from a pool to ensure thread-safety.
// Lua states are NOT thread-safe, so we use a pool with mutex protection.
//
// Script Caching:
// Scripts are cached using the shared FileCache module which supports
// multiple reload strategies: never, auto, and force.

const LuaStatePool = struct {
    states: []*ziglua.Lua,
    states_len: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, initial_size: usize) !LuaStatePool {
        const states = try allocator.alloc(*ziglua.Lua, initial_size * 2); // Allocate space for growth

        // Pre-allocate Lua states
        var i: usize = 0;
        while (i < initial_size) : (i += 1) {
            var lua = try ziglua.Lua.init(allocator);
            lua.openLibs();
            states[i] = lua;
        }

        return LuaStatePool{
            .states = states,
            .states_len = initial_size,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *LuaStatePool) void {
        for (self.states[0..self.states_len]) |lua| {
            lua.deinit();
        }
        self.allocator.free(self.states);
    }

    fn acquire(self: *LuaStatePool) !*ziglua.Lua {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.states_len > 0) {
            self.states_len -= 1;
            return self.states[self.states_len];
        }

        // Create new state if pool is empty
        var lua = try ziglua.Lua.init(self.allocator);
        lua.openLibs();
        return lua;
    }

    fn release(self: *LuaStatePool, lua: *ziglua.Lua) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clear the stack before returning to pool
        lua.setTop(0);

        // Add back to pool if there's space
        if (self.states_len < self.states.len) {
            self.states[self.states_len] = lua;
            self.states_len += 1;
        } else {
            // Pool is full, just deinit the state
            lua.deinit();
        }
    }
};

pub const LuaHandler = struct {
    allocator: std.mem.Allocator,
    scripts_dir: []const u8,
    pool: LuaStatePool,
    file_cache: *FileCache, // Shared global file cache

    pub fn init(allocator: std.mem.Allocator, scripts_dir: []const u8, file_cache: *FileCache) !LuaHandler {
        // Initialize pool with 4 Lua states
        const pool = try LuaStatePool.init(allocator, 4);

        return LuaHandler{
            .allocator = allocator,
            .scripts_dir = scripts_dir,
            .pool = pool,
            .file_cache = file_cache,
        };
    }

    pub fn deinit(self: *LuaHandler) void {
        self.pool.deinit();
        // Don't deinit file_cache - it's shared and owned by AppContext
    }

    /// Execute a Lua script with request data
    /// Supports both GET and POST methods
    /// Request data format:
    /// {
    ///   "method": "GET" or "POST",
    ///   "path": "/api/test",
    ///   "body": {...},  // For POST requests
    ///   "query": {...}  // For GET requests
    /// }
    pub fn executeScript(self: *LuaHandler, arena: std.mem.Allocator, script_name: []const u8, method: []const u8, path: []const u8, request_data: []const u8) ![]const u8 {
        // Get a Lua state from the pool
        var lua = try self.pool.acquire();
        defer self.pool.release(lua);

        // Load and execute script file
        const script_content = try self.loadScript(script_name);
        defer self.allocator.free(script_content);

        // Convert to null-terminated string for Lua using arena allocator
        const script_z = try arena.dupeZ(u8, script_content);
        // No defer needed for arena-allocated memory

        // Load the script (doesn't execute yet)
        lua.doString(script_z) catch |err| {
            std.debug.print("Error loading Lua script: {}\n", .{err});
            return try arena.dupe(u8,
                \\{"status":"error","message":"Lua script load failed"}
            );
        };

        // The script should return a table with a 'handle' function
        // Get the module table from the stack
        if (lua.getTop() != 1) {
            return try arena.dupe(u8,
                \\{"status":"error","message":"Script must return a table"}
            );
        }

        // Get the handle function from the table
        _ = lua.getField(1, "handle");
        if (lua.typeOf(-1) != .function) {
            return try arena.dupe(u8,
                \\{"status":"error","message":"Script must export a 'handle' function"}
            );
        }

        // Create request table
        lua.newTable();

        // Add method
        _ = lua.pushString(method);
        lua.setField(-2, "method");

        // Add path
        _ = lua.pushString(path);
        lua.setField(-2, "path");

        // Parse and add request body/query if present
        if (request_data.len > 0) {
            // Note: Using arena allocator which doesn't require manual cleanup
            const parsed = std.json.parseFromSlice(std.json.Value, arena, request_data, .{}) catch |err| {
                std.debug.print("JSON parse error: {}\n", .{err});
                lua.pop(2); // Pop function and table
                return try arena.dupe(u8,
                    \\{"status":"error","message":"Invalid JSON in request body"}
                );
            };
            // No defer for arena-allocated memory

            // Add body field
            self.pushJsonValue(lua, parsed.value) catch {
                lua.pop(2);
                return try arena.dupe(u8,
                    \\{"status":"error","message":"Failed to convert JSON to Lua"}
                );
            };
            lua.setField(-2, "body");
        }

        // Call the handle function with request table
        lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
            std.debug.print("Error calling Lua handler: {}\n", .{err});
            return try arena.dupe(u8,
                \\{"status":"error","message":"Lua handler execution failed"}
            );
        };

        // Convert return value to JSON using arena allocator
        const response_json = try self.luaValueToJson(arena, lua, -1);
        lua.pop(1); // Pop the return value

        return response_json;
    }

    pub fn loadScript(self: *LuaHandler, script_name: []const u8) ![]const u8 {
        // Security: Prevent path traversal attacks
        if (std.mem.indexOf(u8, script_name, "..") != null or
            std.mem.indexOf(u8, script_name, "/") != null or
            std.mem.indexOf(u8, script_name, "\\") != null)
        {
            return error.InvalidScriptName;
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.lua", .{ self.scripts_dir, script_name });

        // Use the shared FileCache to load the script
        return try self.file_cache.loadFile(path);
    }

    fn pushJsonValue(self: *LuaHandler, lua: *ziglua.Lua, value: std.json.Value) !void {
        switch (value) {
            .null => lua.pushNil(),
            .bool => |b| lua.pushBoolean(b),
            .integer => |i| lua.pushInteger(@intCast(i)),
            .float => |f| lua.pushNumber(f),
            .number_string => |ns| {
                const num = std.fmt.parseFloat(f64, ns) catch {
                    _ = lua.pushString(ns);
                    return;
                };
                lua.pushNumber(num);
            },
            .string => |s| _ = lua.pushString(s),
            .array => |arr| {
                lua.newTable();
                for (arr.items, 0..) |item, i| {
                    try self.pushJsonValue(lua, item);
                    lua.rawSetIndex(-2, @intCast(i + 1));
                }
            },
            .object => |obj| {
                lua.newTable();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    _ = lua.pushString(entry.key_ptr.*);
                    try self.pushJsonValue(lua, entry.value_ptr.*);
                    lua.setTable(-3);
                }
            },
        }
    }

    fn luaValueToJson(self: *LuaHandler, allocator: std.mem.Allocator, lua: *ziglua.Lua, index: i32) ![]const u8 {
        const lua_type = lua.typeOf(index);

        switch (lua_type) {
            .nil => return try allocator.dupe(u8, "null"),
            .boolean => {
                const b = lua.toBoolean(index);
                return try allocator.dupe(u8, if (b) "true" else "false");
            },
            .number => {
                if (lua.isInteger(index)) {
                    const i = lua.toInteger(index) catch 0;
                    return try std.fmt.allocPrint(allocator, "{d}", .{i});
                } else {
                    const n = lua.toNumber(index) catch 0.0;
                    return try std.fmt.allocPrint(allocator, "{d}", .{n});
                }
            },
            .string => {
                const s = lua.toString(index) catch "";
                // Escape JSON string
                var buf = std.ArrayListUnmanaged(u8){};
                defer buf.deinit(allocator);
                try buf.append(allocator, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try buf.appendSlice(allocator, "\\\""),
                        '\\' => try buf.appendSlice(allocator, "\\\\"),
                        '\n' => try buf.appendSlice(allocator, "\\n"),
                        '\r' => try buf.appendSlice(allocator, "\\r"),
                        '\t' => try buf.appendSlice(allocator, "\\t"),
                        else => try buf.append(allocator, c),
                    }
                }
                try buf.append(allocator, '"');
                return try buf.toOwnedSlice(allocator);
            },
            .table => {
                // Check if it's an array or object
                const len = lua.rawLen(index);
                const is_array = len > 0;

                var buf = std.ArrayListUnmanaged(u8){};
                defer buf.deinit(allocator);

                if (is_array) {
                    try buf.append(allocator, '[');
                    var i: i32 = 1;
                    while (i <= len) : (i += 1) {
                        if (i > 1) try buf.append(allocator, ',');
                        _ = lua.rawGetIndex(index, i);
                        const value_json = try self.luaValueToJson(allocator, lua, -1);
                        // No defer needed: using arena allocator which handles cleanup
                        try buf.appendSlice(allocator, value_json);
                        lua.pop(1);
                    }
                    try buf.append(allocator, ']');
                } else {
                    try buf.append(allocator, '{');
                    lua.pushNil();
                    var first = true;
                    while (lua.next(index - 1)) {
                        if (!first) try buf.append(allocator, ',');
                        first = false;

                        // Get key as string
                        const key = lua.toString(-2) catch "unknown";
                        try buf.append(allocator, '"');
                        try buf.appendSlice(allocator, key);
                        try buf.appendSlice(allocator, "\":");

                        // Get value
                        const value_json = try self.luaValueToJson(allocator, lua, -1);
                        // No defer needed: using arena allocator which handles cleanup
                        try buf.appendSlice(allocator, value_json);

                        lua.pop(1); // Pop value, keep key for next iteration
                    }
                    try buf.append(allocator, '}');
                }

                return try buf.toOwnedSlice(allocator);
            },
            else => {
                return try allocator.dupe(u8, "null");
            },
        }
    }
};

test "lua handler init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer cache.deinit();

    var handler = try LuaHandler.init(allocator, "./examples/lua", &cache);
    defer handler.deinit();

    try testing.expect(handler.scripts_dir.len > 0);
}

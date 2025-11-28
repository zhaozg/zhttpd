const std = @import("std");
const ziglua = @import("ziglua");
const FileCache = @import("../cache/file_cache.zig").FileCache;
const build_options = @import("build_options");

// Lua integration module
// This module provides integration with Lua for dynamic content handling
// Based on ziglua: https://github.com/natecraddock/ziglua
//
// Thread Safety:
// Each HTTP worker thread has its own dedicated Lua VM via thread-local storage.
// This eliminates mutex contention and provides better performance than pooling.
//
// Script Caching:
// Scripts are cached using the shared FileCache module which supports
// multiple reload strategies: never, auto, and force.
//
// Phase 1 Enhanced Features:
// - Complex request data structures (headers, query parameters) in luvit/Node.js style
// - Script hot-reloading via FileCache auto mode
// - Bytecode caching and precompilation for performance
// - Sandboxing with instruction count limits for resource control
//
// LuaJIT Support:
// When built with -Dlua-lang=luajit, uses LuaJIT instead of standard Lua 5.4.
// LuaJIT provides JIT compilation for better performance but is based on Lua 5.1.

/// Returns the Lua engine name for display purposes
pub fn getLuaEngineName() []const u8 {
    return if (build_options.lua_lang == .luajit) "LuaJIT" else "Lua 5.4";
}

/// Maximum size for header/query parameter keys when passing to Lua
const MAX_KEY_SIZE: usize = 256;

/// Configuration for Lua sandbox limits
/// All settings have safe defaults that can be overridden via configuration
pub const SandboxConfig = struct {
    /// Maximum number of Lua instructions per script execution (0 = unlimited)
    /// Default: 100,000 instructions (safe default to prevent infinite loops)
    max_instructions: u32 = 100_000,
    /// Maximum memory in bytes for Lua state (0 = unlimited, not yet implemented)
    max_memory: usize = 0,
    /// Enable sandboxing (disables dangerous functions)
    /// Default: true (safe default to prevent malicious scripts)
    enable_sandbox: bool = true,
};

/// Default sandbox configuration with safe defaults
pub const default_sandbox_config = SandboxConfig{};

/// Bytecode cache entry (reserved for future bytecode precompilation)
const BytecodeEntry = struct {
    bytecode: []const u8,
    mtime: i128,
};

/// Instruction limit hook - called by Lua when instruction count is reached
/// This throws an error to stop script execution if limit is exceeded
fn instructionLimitHook(lua: *ziglua.Lua, _: ziglua.Event, _: *ziglua.DebugInfo) void {
    // Raise an error to stop execution
    _ = lua.raiseErrorStr("instruction limit exceeded", .{});
}

/// No-op hook used to reset hooks after script execution
fn noopHook(_: *ziglua.Lua, _: ziglua.Event, _: *ziglua.DebugInfo) void {}

/// Thread-local Lua state wrapper
/// Each HTTP worker thread gets its own Lua VM for optimal performance
const ThreadLocalLua = struct {
    lua: *ziglua.Lua,
    allocator: std.mem.Allocator,
    sandbox_config: SandboxConfig,

    fn init(allocator: std.mem.Allocator, sandbox_config: SandboxConfig) !ThreadLocalLua {
        var lua = try ziglua.Lua.init(allocator);
        lua.openLibs();
        if (sandbox_config.enable_sandbox) {
            applySandbox(lua);
        }
        return ThreadLocalLua{
            .lua = lua,
            .allocator = allocator,
            .sandbox_config = sandbox_config,
        };
    }

    fn deinit(self: *ThreadLocalLua) void {
        self.lua.deinit();
    }

    /// Apply sandbox restrictions by removing dangerous functions
    fn applySandbox(lua: *ziglua.Lua) void {
        // Remove dangerous global functions for sandboxing
        // These could be used to escape the sandbox or cause harm
        const dangerous_globals = [_][:0]const u8{
            "loadfile",
            "dofile",
            "load", // Can execute arbitrary Lua code from strings
            "loadstring", // Lua 5.1 equivalent of load
        };

        for (dangerous_globals) |name| {
            lua.pushNil();
            lua.setGlobal(name);
        }

        // Remove dangerous os functions (keep safe ones like os.time, os.date)
        _ = lua.getGlobal("os") catch {};
        if (lua.typeOf(-1) == .table) {
            const dangerous_os_funcs = [_][:0]const u8{
                "execute",
                "exit",
                "remove",
                "rename",
                "setlocale",
                "tmpname",
                "getenv",
            };
            for (dangerous_os_funcs) |name| {
                lua.pushNil();
                lua.setField(-2, name);
            }
        }
        lua.pop(1);

        // Remove dangerous io functions
        lua.pushNil();
        lua.setGlobal("io");

        // Remove debug library (can be used to escape sandbox)
        lua.pushNil();
        lua.setGlobal("debug");

        // Remove package library (can load arbitrary C libraries via package.loadlib)
        lua.pushNil();
        lua.setGlobal("package");

        // Register built-in cjson module (safe, sandboxed JSON handling)
        registerCjsonModule(lua);
    }

    /// Register the built-in cjson module
    /// Provides cjson-compatible API: cjson.encode() and cjson.decode()
    fn registerCjsonModule(lua: *ziglua.Lua) void {
        // Create the cjson table
        lua.newTable();

        // Add encode function
        lua.pushFunction(ziglua.wrap(cjsonEncode));
        lua.setField(-2, "encode");

        // Add decode function
        lua.pushFunction(ziglua.wrap(cjsonDecode));
        lua.setField(-2, "decode");

        // Add null value (cjson.null) - use a unique sentinel value
        // We use a small integer as a sentinel since light userdata requires non-null
        lua.pushNil();
        lua.setField(-2, "null");

        // Set as global 'cjson'
        lua.setGlobal("cjson");
    }

    /// cjson.encode(value) - Convert Lua value to JSON string
    fn cjsonEncode(lua: *ziglua.Lua) i32 {
        // Check if we have an argument
        if (lua.getTop() < 1) {
            _ = lua.pushString("cjson.encode: requires 1 argument");
            lua.raiseError();
        }

        // Get thread-local allocator
        const allocator = if (tls_lua) |tl| tl.allocator else std.heap.page_allocator;

        // Use a temporary arena for JSON encoding
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const json_str = luaValueToJsonStatic(arena.allocator(), lua, 1) catch {
            _ = lua.pushString("cjson.encode: failed to encode value");
            lua.raiseError();
        };

        _ = lua.pushString(json_str);
        return 1;
    }

    /// cjson.decode(json_string) - Parse JSON string to Lua value
    fn cjsonDecode(lua: *ziglua.Lua) i32 {
        // Check if we have an argument
        if (lua.getTop() < 1) {
            _ = lua.pushString("cjson.decode: requires 1 argument");
            lua.raiseError();
        }

        // Check if argument is a string
        if (lua.typeOf(1) != .string) {
            _ = lua.pushString("cjson.decode: argument must be a string");
            lua.raiseError();
        }

        const json_str = lua.toString(1) catch {
            _ = lua.pushString("cjson.decode: failed to get string");
            lua.raiseError();
        };

        // Get thread-local allocator
        const allocator = if (tls_lua) |tl| tl.allocator else std.heap.page_allocator;

        // Use a temporary arena for JSON parsing
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json_str, .{}) catch {
            _ = lua.pushString("cjson.decode: invalid JSON");
            lua.raiseError();
        };

        pushJsonValueStatic(lua, parsed.value) catch {
            _ = lua.pushString("cjson.decode: failed to convert JSON to Lua");
            lua.raiseError();
        };

        return 1;
    }

    /// Static version of pushJsonValue for use in cjson functions
    fn pushJsonValueStatic(lua: *ziglua.Lua, value: std.json.Value) !void {
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
                    try pushJsonValueStatic(lua, item);
                    lua.rawSetIndex(-2, @intCast(i + 1));
                }
            },
            .object => |obj| {
                lua.newTable();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    _ = lua.pushString(entry.key_ptr.*);
                    try pushJsonValueStatic(lua, entry.value_ptr.*);
                    lua.setTable(-3);
                }
            },
        }
    }

    /// Static version of luaValueToJson for use in cjson functions
    fn luaValueToJsonStatic(allocator: std.mem.Allocator, lua: *ziglua.Lua, index: i32) ![]const u8 {
        const lua_type = lua.typeOf(index);

        switch (lua_type) {
            .nil => return try allocator.dupe(u8, "null"),
            .boolean => {
                const b = lua.toBoolean(index);
                return try allocator.dupe(u8, if (b) "true" else "false");
            },
            .number => {
                const n = lua.toNumber(index) catch 0.0;
                const is_whole_number = @floor(n) == n and n >= -9007199254740992 and n <= 9007199254740992;
                if (is_whole_number) {
                    const i: i64 = @intFromFloat(n);
                    return try std.fmt.allocPrint(allocator, "{d}", .{i});
                } else {
                    return try std.fmt.allocPrint(allocator, "{d}", .{n});
                }
            },
            .string => {
                const s = lua.toString(index) catch "";
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
                        const value_json = try luaValueToJsonStatic(allocator, lua, -1);
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

                        const key = lua.toString(-2) catch "unknown";
                        try buf.append(allocator, '"');
                        try buf.appendSlice(allocator, key);
                        try buf.appendSlice(allocator, "\":");

                        const value_json = try luaValueToJsonStatic(allocator, lua, -1);
                        try buf.appendSlice(allocator, value_json);

                        lua.pop(1);
                    }
                    try buf.append(allocator, '}');
                }

                return try buf.toOwnedSlice(allocator);
            },
            .light_userdata => {
                // cjson.null is represented as light userdata with null pointer
                return try allocator.dupe(u8, "null");
            },
            else => {
                return try allocator.dupe(u8, "null");
            },
        }
    }
};

/// Thread-local storage for Lua VM
/// Each worker thread automatically gets its own Lua state
threadlocal var tls_lua: ?ThreadLocalLua = null;

/// Key-value pair for headers and query parameters (luvit/Node.js style)
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Helper function to push a key-value table entry to Lua
/// Handles null-termination of keys for Lua's setField API
fn pushKeyValueToTable(lua: *ziglua.Lua, key: []const u8, value: []const u8) void {
    _ = lua.pushString(value);
    // Create null-terminated key for setField
    var key_buf: [MAX_KEY_SIZE]u8 = undefined;
    const key_len = @min(key.len, key_buf.len - 1);
    if (key.len >= key_buf.len) {
        std.debug.print("Warning: key truncated from {} to {} bytes: \"{s}\"\n", .{ key.len, key_len, key[0..@min(key.len, 64)] });
    }
    @memcpy(key_buf[0..key_len], key[0..key_len]);
    key_buf[key_len] = 0;
    lua.setField(-2, key_buf[0..key_len :0]);
}

pub const LuaHandler = struct {
    allocator: std.mem.Allocator,
    scripts_dir: []const u8,
    file_cache: *FileCache, // Shared global file cache
    sandbox_config: SandboxConfig,
    // Bytecode cache for precompiled Lua scripts (infrastructure for future optimization)
    // Currently the cache is initialized but bytecode precompilation is not yet implemented.
    // The FileCache already handles source caching; bytecode caching would add precompilation.
    bytecode_cache: std.StringHashMap(BytecodeEntry),
    bytecode_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, scripts_dir: []const u8, file_cache: *FileCache) !LuaHandler {
        return initWithConfig(allocator, scripts_dir, file_cache, default_sandbox_config);
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, scripts_dir: []const u8, file_cache: *FileCache, sandbox_config: SandboxConfig) !LuaHandler {
        return LuaHandler{
            .allocator = allocator,
            .scripts_dir = scripts_dir,
            .file_cache = file_cache,
            .sandbox_config = sandbox_config,
            .bytecode_cache = std.StringHashMap(BytecodeEntry).init(allocator),
            .bytecode_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *LuaHandler) void {
        // Clean up bytecode cache
        self.bytecode_mutex.lock();
        defer self.bytecode_mutex.unlock();

        var it = self.bytecode_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.bytecode);
        }
        self.bytecode_cache.deinit();
        // Don't deinit file_cache - it's shared and owned by AppContext
        // Note: Thread-local Lua states are managed per-thread. In httpz's
        // worker pool model, threads persist for the server lifetime and their
        // TLS Lua states remain valid. When the server shuts down, the process
        // exits and all memory is reclaimed by the OS. For explicit cleanup,
        // call deinitThreadLocalLua() from each worker thread before shutdown.
    }

    /// Cleanup thread-local Lua state for the current thread.
    /// Call this from each worker thread during graceful shutdown if needed.
    /// In most cases, this is not necessary as the OS reclaims memory on process exit.
    pub fn deinitThreadLocalLua() void {
        if (tls_lua) |*tl| {
            tl.deinit();
            tls_lua = null;
        }
    }

    /// Get or create the thread-local Lua state for the current worker thread
    fn getThreadLocalLua(self: *LuaHandler) !*ziglua.Lua {
        if (tls_lua) |*tl| {
            return tl.lua;
        }
        // Initialize thread-local Lua state for this worker thread
        tls_lua = try ThreadLocalLua.init(self.allocator, self.sandbox_config);
        // tls_lua is guaranteed to be non-null after successful init
        return tls_lua.?.lua;
    }

    /// Clear bytecode cache (useful for hot-reloading)
    pub fn clearBytecodeCache(self: *LuaHandler) void {
        self.bytecode_mutex.lock();
        defer self.bytecode_mutex.unlock();

        var it = self.bytecode_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.bytecode);
        }
        self.bytecode_cache.clearRetainingCapacity();
    }

    /// Execute a Lua script with request data (legacy interface for compatibility)
    /// Supports both GET and POST methods
    /// Request data format:
    /// {
    ///   "method": "GET" or "POST",
    ///   "path": "/api/test",
    ///   "body": {...},  // For POST requests
    ///   "query": {...}  // For GET requests
    /// }
    pub fn executeScript(self: *LuaHandler, arena: std.mem.Allocator, script_name: []const u8, method: []const u8, path: []const u8, request_data: []const u8) ![]const u8 {
        // Call new enhanced function with empty headers and query
        return self.executeScriptEx(arena, script_name, method, path, request_data, &[_]KeyValue{}, &[_]KeyValue{});
    }

    /// Execute a Lua script with full request data including headers and query parameters
    /// This provides a luvit/Node.js style API where the request object contains:
    /// - method: HTTP method (GET, POST, etc.)
    /// - path: Request path
    /// - body: Parsed request body (for POST/PUT)
    /// - headers: Table of request headers
    /// - query: Table of query parameters
    /// - url: Full URL path
    pub fn executeScriptEx(
        self: *LuaHandler,
        arena: std.mem.Allocator,
        script_name: []const u8,
        method: []const u8,
        path: []const u8,
        request_data: []const u8,
        headers: []const KeyValue,
        query_params: []const KeyValue,
    ) ![]const u8 {
        // Get the thread-local Lua state (one per worker thread)
        var lua = try self.getThreadLocalLua();

        // Clear the stack before starting
        lua.setTop(0);

        // Set up instruction limit hook if configured
        if (self.sandbox_config.max_instructions > 0) {
            lua.setHook(ziglua.wrap(instructionLimitHook), .{ .count = true }, @intCast(self.sandbox_config.max_instructions));
        }

        // Load and execute script file
        // Note: loadScript returns memory allocated by file_cache.allocator (which is self.allocator)
        const script_content = try self.loadScript(script_name);
        defer self.allocator.free(script_content);

        // Convert to null-terminated string for Lua using arena allocator
        const script_z = try arena.dupeZ(u8, script_content);
        // No defer needed for arena-allocated memory

        // Load the script (doesn't execute yet)
        lua.doString(script_z) catch |err| {
            std.debug.print("Error loading Lua script: {}\n", .{err});
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Lua script load failed"}
            );
        };

        // The script should return a table with a 'handle' function
        // Get the module table from the stack
        if (lua.getTop() != 1) {
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Script must return a table"}
            );
        }

        // Get the handle function from the table
        _ = lua.getField(1, "handle");
        if (lua.typeOf(-1) != .function) {
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Script must export a 'handle' function"}
            );
        }

        // Create request table (luvit/Node.js style)
        lua.newTable();

        // Add method
        _ = lua.pushString(method);
        lua.setField(-2, "method");

        // Add path and url (alias for path, luvit style)
        _ = lua.pushString(path);
        lua.pushValue(-1); // Duplicate the path value on stack
        lua.setField(-3, "path");
        lua.setField(-2, "url");

        // Add headers table (luvit/Node.js style)
        lua.newTable();
        for (headers) |header| {
            pushKeyValueToTable(lua, header.key, header.value);
        }
        lua.setField(-2, "headers");

        // Add query table (luvit/Node.js style)
        lua.newTable();
        for (query_params) |param| {
            pushKeyValueToTable(lua, param.key, param.value);
        }
        lua.setField(-2, "query");

        // Parse and add request body/query if present
        if (request_data.len > 0) {
            // Note: Using arena allocator which doesn't require manual cleanup
            const parsed = std.json.parseFromSlice(std.json.Value, arena, request_data, .{}) catch |err| {
                std.debug.print("JSON parse error: {}\n", .{err});
                lua.pop(2); // Pop function and table
                lua.setHook(ziglua.wrap(noopHook), .{}, 0);
                return try arena.dupe(u8,
                    \\{"status":"error","message":"Invalid JSON in request body"}
                );
            };
            // No defer for arena-allocated memory

            // Add body field
            self.pushJsonValue(lua, parsed.value) catch {
                lua.pop(2);
                lua.setHook(ziglua.wrap(noopHook), .{}, 0);
                return try arena.dupe(u8,
                    \\{"status":"error","message":"Failed to convert JSON to Lua"}
                );
            };
            lua.setField(-2, "body");
        }

        // Call the handle function with request table
        lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
            std.debug.print("Error calling Lua handler: {}\n", .{err});
            // Note: When instruction limit is exceeded, the hook raises an error
            // which is caught here. We can't distinguish between instruction limit
            // and other Lua errors, so we return a generic error message.
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Lua handler execution failed"}
            );
        };

        // Convert return value to JSON using arena allocator
        const response_json = try self.luaValueToJson(arena, lua, -1);
        lua.pop(1); // Pop the return value

        // Clear instruction limit hook
        lua.setHook(ziglua.wrap(noopHook), .{}, 0);

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
                // LuaJIT (Lua 5.1) doesn't have isInteger, so we check if the number is a whole number
                const n = lua.toNumber(index) catch 0.0;
                // Check if it's a whole number that can be represented as an integer
                const is_whole_number = @floor(n) == n and n >= -9007199254740992 and n <= 9007199254740992;
                if (is_whole_number) {
                    const i: i64 = @intFromFloat(n);
                    return try std.fmt.allocPrint(allocator, "{d}", .{i});
                } else {
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

test "lua handler init with sandbox config" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer cache.deinit();

    const config = SandboxConfig{
        .max_instructions = 50_000,
        .enable_sandbox = true,
    };

    var handler = try LuaHandler.initWithConfig(allocator, "./examples/lua", &cache, config);
    defer handler.deinit();

    try testing.expect(handler.sandbox_config.max_instructions == 50_000);
    try testing.expect(handler.sandbox_config.enable_sandbox == true);
}

test "lua handler executeScriptEx with headers and query" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer cache.deinit();

    // Disable sandbox for this test as the example scripts may use io/debug
    const config = SandboxConfig{
        .max_instructions = 0,
        .enable_sandbox = false,
    };

    var handler = try LuaHandler.initWithConfig(allocator, "./examples/lua", &cache, config);
    defer handler.deinit();

    // Create test headers and query params
    const headers = [_]KeyValue{
        .{ .key = "content-type", .value = "application/json" },
        .{ .key = "user-agent", .value = "test-client" },
    };

    const query_params = [_]KeyValue{
        .{ .key = "page", .value = "1" },
        .{ .key = "limit", .value = "10" },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try handler.executeScriptEx(
        arena.allocator(),
        "test",
        "GET",
        "/api/test",
        "",
        &headers,
        &query_params,
    );

    // Verify we got a response
    try testing.expect(result.len > 0);
    // The test.lua script returns a JSON object with status "success"
    try testing.expect(std.mem.indexOf(u8, result, "success") != null);
}

test "lua handler bytecode cache clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer cache.deinit();

    var handler = try LuaHandler.init(allocator, "./examples/lua", &cache);
    defer handler.deinit();

    // Clear bytecode cache should not fail
    handler.clearBytecodeCache();

    try testing.expect(handler.bytecode_cache.count() == 0);
}

test "cjson module encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer cache.deinit();

    // Enable sandbox to test cjson module (cjson is only available with sandbox enabled)
    const config = SandboxConfig{
        .max_instructions = 100_000,
        .enable_sandbox = true,
    };

    var handler = try LuaHandler.initWithConfig(allocator, "./examples/lua", &cache, config);
    defer handler.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try handler.executeScriptEx(
        arena.allocator(),
        "cjson_test",
        "GET",
        "/api/cjson_test",
        "",
        &[_]KeyValue{},
        &[_]KeyValue{},
    );

    // Verify we got a successful response
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "success") != null);
    // Verify cjson was available
    try testing.expect(std.mem.indexOf(u8, result, "cjson_available") != null);
    try testing.expect(std.mem.indexOf(u8, result, "true") != null);
}

test "getLuaEngineName returns correct engine name" {
    const engine_name = getLuaEngineName();
    try std.testing.expect(engine_name.len > 0);
    // Either "LuaJIT" or "Lua 5.4"
    try std.testing.expect(std.mem.eql(u8, engine_name, "LuaJIT") or std.mem.eql(u8, engine_name, "Lua 5.4"));
}

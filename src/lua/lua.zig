const std = @import("std");
const ziglua = @import("ziglua");
const httpz = @import("httpz");
const FileCache = @import("../cache/file_cache.zig").FileCache;
const build_options = @import("build_options");
const json = @import("json.zig");
const context = @import("context.zig");

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
        json.registerCjsonModule(lua, &getThreadLocalAllocator);

        // Register context module for Per-Request Context support
        // Note: Database access is now through context:db(name) instead of global db
        context.registerContextModule(lua);
    }
};

/// Get allocator from thread-local storage for use by json module
fn getThreadLocalAllocator() std.mem.Allocator {
    return if (tls_lua) |tl| tl.allocator else std.heap.page_allocator;
}

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
            json.pushJsonValue(lua, parsed.value) catch {
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
        const response_json = try json.luaValueToJson(arena, lua, -1);
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

    /// Execute a Lua script with Per-Request Context (httpz integration)
    ///
    /// This method provides direct access to httpz.Request and httpz.Response
    /// objects from Lua scripts via the `ctx` parameter:
    ///
    /// ```lua
    /// function handle(ctx)
    ///     -- Access request data
    ///     local method = ctx.req:method()
    ///     local path = ctx.req:path()
    ///     local header = ctx.req:header("content-type")
    ///     local body = ctx.req:body()
    ///
    ///     -- Set response data
    ///     ctx.res:status(200)
    ///     ctx.res:header("X-Custom-Header", "value")
    ///     ctx.res:content_type("application/json")
    ///
    ///     -- Use per-request data storage
    ///     ctx.data.user_id = "12345"
    ///
    ///     return { status = "success" }
    /// end
    /// ```
    ///
    /// Returns the JSON-encoded response body from the Lua handler.
    pub fn executeScriptWithContext(
        self: *LuaHandler,
        script_name: []const u8,
        req: *httpz.Request,
        res: *httpz.Response,
    ) ![]const u8 {
        const arena = res.arena;

        // Get the thread-local Lua state (one per worker thread)
        var lua = try self.getThreadLocalLua();

        // Clear the stack before starting
        lua.setTop(0);

        // Set up instruction limit hook if configured
        if (self.sandbox_config.max_instructions > 0) {
            lua.setHook(ziglua.wrap(instructionLimitHook), .{ .count = true }, @intCast(self.sandbox_config.max_instructions));
        }

        // Ensure context is cleared on exit
        defer context.clearContext();

        // Load and execute script file
        const script_content = try self.loadScript(script_name);
        defer self.allocator.free(script_content);

        // Convert to null-terminated string for Lua
        const script_z = try arena.dupeZ(u8, script_content);

        // Load the script
        lua.doString(script_z) catch |err| {
            std.debug.print("Error loading Lua script: {}\n", .{err});
            lua.setTop(0); // Clean up stack before returning
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Lua script load failed"}
            );
        };

        // The script should return a table with a 'handle' function
        if (lua.getTop() != 1) {
            lua.setTop(0); // Clean up stack before returning
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Script must return a table"}
            );
        }

        // Get the handle function from the table
        _ = lua.getField(1, "handle");
        if (lua.typeOf(-1) != .function) {
            lua.setTop(0); // Clean up stack before returning
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Script must export a 'handle' function"}
            );
        }

        // Push handler arguments: request, response, context (3 arguments)
        context.pushHandlerArgs(lua, req, res, arena);

        // Call the handle function with 3 arguments: handle(request, response, context)
        lua.protectedCall(.{ .args = 3, .results = 1 }) catch |err| {
            std.debug.print("Error calling Lua handler: {}\n", .{err});
            lua.setTop(0); // Clean up stack before returning
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return try arena.dupe(u8,
                \\{"status":"error","message":"Lua handler execution failed"}
            );
        };

        // Convert return value to JSON
        const response_json = try json.luaValueToJson(arena, lua, -1);
        lua.pop(1);

        // Clear instruction limit hook
        lua.setHook(ziglua.wrap(noopHook), .{}, 0);

        return response_json;
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
    // Verify special character escaping works
    try testing.expect(std.mem.indexOf(u8, result, "special_chars_valid") != null);
    try testing.expect(std.mem.indexOf(u8, result, "deep_valid") != null);
}

test "getLuaEngineName returns correct engine name" {
    const engine_name = getLuaEngineName();
    try std.testing.expect(engine_name.len > 0);
    // Either "LuaJIT" or "Lua 5.4"
    try std.testing.expect(std.mem.eql(u8, engine_name, "LuaJIT") or std.mem.eql(u8, engine_name, "Lua 5.4"));
}

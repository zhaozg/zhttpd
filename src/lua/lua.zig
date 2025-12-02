const std = @import("std");
const ziglua = @import("ziglua");
const httpz = @import("httpz");
const FileCache = @import("../cache/file_cache.zig").FileCache;
const build_options = @import("build_options");
const json = @import("json.zig");
const lpeg = @import("lpeg.zig");
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

/// Pre-defined error response strings (optimization: avoids allocation on error paths)
const ERR_SCRIPT_LOAD_FAILED =
    \\{"status":"error","message":"Lua script load failed"}
;
const ERR_SCRIPT_MUST_RETURN_TABLE =
    \\{"status":"error","message":"Script must return a table"}
;
const ERR_SCRIPT_MUST_EXPORT_HANDLE =
    \\{"status":"error","message":"Script must export a 'handle' function"}
;
const ERR_HANDLER_EXECUTION_FAILED =
    \\{"status":"error","message":"Lua handler execution failed"}
;

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
    /// Reference to the module cache table in Lua registry
    module_cache_ref: i32,

    fn init(allocator: std.mem.Allocator, sandbox_config: SandboxConfig) !ThreadLocalLua {
        var lua = try ziglua.Lua.init(allocator);
        lua.openLibs();

        // Always register built-in json module (safe for use with or without sandbox)
        json.registerJsonModule(lua, &getThreadLocalAllocator);

        // Always register built-in lpeg module (safe for use with or without sandbox)
        lpeg.registerLpegModule(lua, &getThreadLocalAllocator);

        // Always register context module for Per-Request Context support
        context.registerContextModule(lua);

        if (sandbox_config.enable_sandbox) {
            applySandbox(lua);
        }

        // Create module cache table and store reference in registry
        lua.newTable();
        const module_cache_ref = lua.ref(ziglua.registry_index) catch {
            lua.deinit();
            return error.LuaError;
        };

        return ThreadLocalLua{
            .lua = lua,
            .allocator = allocator,
            .sandbox_config = sandbox_config,
            .module_cache_ref = module_cache_ref,
        };
    }

    fn deinit(self: *ThreadLocalLua) void {
        // Release the module cache reference before deinitializing
        self.lua.unref(ziglua.registry_index, self.module_cache_ref);
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
    pub fn getThreadLocalLua(self: *LuaHandler) !*ziglua.Lua {
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

    /// Clear the module cache in the thread-local Lua registry.
    /// Call this to invalidate cached modules when scripts are reloaded.
    /// This creates a fresh empty table and replaces the old cache.
    ///
    /// Note: This only affects the current thread's cache. Each worker thread
    /// has its own thread-local Lua state with its own module cache.
    /// To clear caches in all threads, call this from each worker thread.
    pub fn clearModuleCache(self: *LuaHandler) void {
        _ = self; // Instance method for API consistency with clearBytecodeCache
        if (tls_lua) |*tl| {
            // Unref the old cache table
            tl.lua.unref(ziglua.registry_index, tl.module_cache_ref);
            // Create a new empty cache table
            tl.lua.newTable();
            tl.module_cache_ref = tl.lua.ref(ziglua.registry_index) catch {
                // If ref fails (very unlikely), reset to an invalid ref
                // The module will just not use caching
                tl.module_cache_ref = ziglua.ref_nil;
                return;
            };
        }
    }

    /// Get cached module table or load and cache it.
    /// Returns true if module table is on top of stack, false on error.
    /// Uses zerocopy: script_content is passed directly to loadBuffer without copying.
    ///
    /// Caching behavior by reload mode:
    /// - 'force': Always skip cache, reload script every time
    /// - 'never': Always use cache (file changes not detected)
    /// - 'auto': Cache is bypassed since file content may change
    ///
    /// Stack effect on success: pushes module table
    /// Stack effect on failure: stack unchanged
    pub fn getOrLoadModule(self: *LuaHandler, lua: *ziglua.Lua, script_name: []const u8, script_content: []const u8) bool {
        const tl = tls_lua orelse return false;

        // Only cache in 'never' mode where file content is guaranteed not to change.
        // In 'force' and 'auto' modes, always reload to respect file changes.
        const use_cache = self.file_cache.reload_mode == .never;

        if (use_cache) {
            // Get the module cache table from registry
            _ = lua.rawGetIndex(ziglua.registry_index, tl.module_cache_ref);
            if (lua.typeOf(-1) != .table) {
                lua.pop(1);
                return false;
            }

            // Check if script_name is in the cache
            _ = lua.pushString(script_name);
            _ = lua.rawGetTable(-2); // Get cache[script_name]

            if (lua.typeOf(-1) == .table) {
                // Cache hit! Module table is on stack
                // Remove the cache table, keeping only the module table
                lua.remove(-2);
                return true;
            }

            // Cache miss - need to load and compile the script
            lua.pop(1); // Pop nil
        }

        // Build chunk name for error messages (stack-allocated, null-terminated)
        var name_buf: [256]u8 = undefined;
        const name_len = @min(script_name.len, name_buf.len - 6); // Reserve space for "@" prefix, ".lua" suffix, and null terminator
        name_buf[0] = '@';
        @memcpy(name_buf[1 .. name_len + 1], script_name[0..name_len]);
        @memcpy(name_buf[name_len + 1 .. name_len + 5], ".lua");
        name_buf[name_len + 5] = 0;
        const chunk_name: [:0]const u8 = name_buf[0 .. name_len + 5 :0];

        // Load script using loadBuffer (zerocopy - no duplication needed)
        // loadBuffer accepts []const u8 directly without null termination
        // Note: Lua 5.1/LuaJIT loadBuffer has 2 args, Lua 5.2+ has 3 args (includes mode)
        const load_result = if (build_options.lua_lang == .luajit)
            lua.loadBuffer(script_content, chunk_name)
        else
            lua.loadBuffer(script_content, chunk_name, .text);
        load_result catch {
            lua.pop(1); // Pop error message left by loadBuffer
            if (use_cache) lua.pop(1); // Pop cache table
            return false;
        };

        // Execute the loaded chunk to get the module table
        lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
            lua.pop(1); // Pop error message left by protectedCall
            if (use_cache) lua.pop(1); // Pop cache table
            return false;
        };

        // Verify result is a table
        if (lua.typeOf(-1) != .table) {
            lua.pop(1); // Pop result
            if (use_cache) lua.pop(1); // Pop cache table
            return false;
        }

        if (use_cache) {
            // Cache the module: cache[script_name] = module_table
            _ = lua.pushString(script_name);
            lua.pushValue(-2); // Copy module table
            lua.rawSetTable(-4); // cache[script_name] = module_table

            // Remove the cache table, keeping only the module table
            lua.remove(-2);
        }
        return true;
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
    /// Execute a Lua script with Per-Request Context
    ///
    /// This method loads and caches Lua scripts, then calls the specified function
    /// with request, response, and context parameters.
    ///
    /// Parameters:
    ///   - script_name: Name of Lua script (without .lua extension)
    ///   - func: Name of the Lua function to call (e.g., "handle", "handle_request")
    ///   - req: HTTP request object
    ///   - res: HTTP response object
    ///
    /// The Lua function is called with 3 arguments: function(request, response, context)
    /// The request object provides access to headers, body, and other request data.
    ///
    /// Returns the JSON-encoded response body from the Lua handler.
    pub fn executeScriptWithContext(
        self: *LuaHandler,
        script_name: []const u8,
        func: []const u8,
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

        // Load script content from file cache (zerocopy path)
        const script_content = try self.loadScript(script_name);
        defer self.allocator.free(script_content);

        // Get cached module or load and cache it (zerocopy: no dupeZ needed)
        if (!self.getOrLoadModule(lua, script_name, script_content)) {
            lua.setTop(0);
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return ERR_SCRIPT_LOAD_FAILED;
        }

        // Module table is now on stack, get the specified function
        // getField requires null-terminated string
        const func_z = try arena.dupeZ(u8, func);
        _ = lua.getField(-1, func_z);
        if (lua.typeOf(-1) != .function) {
            lua.setTop(0); // Clean up stack before returning
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            // Return error indicating the specific function was not found
            std.debug.print("Script '{s}' does not export function '{s}'\n", .{ script_name, func });
            return ERR_SCRIPT_MUST_EXPORT_HANDLE;
        }

        // Remove module table from stack, keep function
        lua.remove(-2);

        // Standard context-based API: function(request, response, context)
        context.pushHandlerArgs(lua, req, res, arena);

        // Call the function with 3 arguments
        lua.protectedCall(.{ .args = 3, .results = 1 }) catch |err| {
            std.debug.print("Error calling Lua handler: {}\n", .{err});
            lua.setTop(0); // Clean up stack before returning
            lua.setHook(ziglua.wrap(noopHook), .{}, 0);
            return ERR_HANDLER_EXECUTION_FAILED;
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

test "getLuaEngineName returns correct engine name" {
    const engine_name = getLuaEngineName();
    try std.testing.expect(engine_name.len > 0);
    // Either "LuaJIT" or "Lua 5.4"
    try std.testing.expect(std.mem.eql(u8, engine_name, "LuaJIT") or std.mem.eql(u8, engine_name, "Lua 5.4"));
}

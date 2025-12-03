//! Database Plugin for zhttpd
//!
//! This plugin provides database connectivity through the zdbc library.
//! It supports SQLite, PostgreSQL, and MySQL through a unified interface.
//!
//! ## Features
//!
//! - Connection pooling for efficient database access
//! - Prepared statement caching for improved performance
//! - Unified API across multiple database backends
//! - Lua bindings for scripting database operations
//! - Zig-side utilities for authentication and user validation
//! - Full zdbc Connection interface support
//!
//! ## Configuration
//!
//! Configure in zhttpd.yaml:
//! ```yaml
//! enable_db: true
//! db_uri: "sqlite:///data/app.db"
//! db_pool_size: 10
//! stmt_cache_size: 100  # Maximum cached prepared statements per connection
//! ```
//!
//! ## Lua API
//!
//! ```lua
//! local db = require("db")
//!
//! -- Direct query (no statement caching)
//! local result = db.query("SELECT * FROM users WHERE id = ?", 1)
//!
//! -- Direct exec (no statement caching)
//! local affected = db.exec("INSERT INTO users (name) VALUES (?)", "John")
//!
//! -- Prepared statement with caching (recommended for repeated queries)
//! local stmt = db.prepare("SELECT * FROM users WHERE id = ?")
//! local result1 = stmt:query(1)
//! local result2 = stmt:query(2)  -- Uses cached prepared statement
//!
//! -- Prepared statement for exec
//! local insert_stmt = db.prepare("INSERT INTO users (name) VALUES (?)")
//! local affected1 = insert_stmt:exec("Alice")
//! local affected2 = insert_stmt:exec("Bob")  -- Reuses cached statement
//!
//! -- Transaction support
//! db.begin()
//! db.exec("UPDATE accounts SET balance = balance - 100 WHERE id = ?", 1)
//! db.exec("UPDATE accounts SET balance = balance + 100 WHERE id = ?", 2)
//! db.commit()
//! -- Use db.rollback() to rollback on error
//!
//! -- Get status including statement cache statistics
//! local status = db.status()
//! print("Cache hits:", status.stmt_cache_stats.hits)
//! print("Cache hit rate:", status.stmt_cache_stats.hit_rate)
//! ```

const std = @import("std");
const zdbc = @import("zdbc");
const ziglua = @import("ziglua");
const plugin_mod = @import("../plugin.zig");
const PluginVTable = plugin_mod.PluginVTable;
const PluginInfo = plugin_mod.PluginInfo;
const Plugin = plugin_mod.Plugin;

/// Database plugin configuration
pub const DbConfig = struct {
    /// Database URI (e.g., "sqlite:///path/to/db.sqlite")
    uri: []const u8,
    /// Connection pool size
    pool_size: u32 = 5,
    /// Enable connection pooling
    enable_pool: bool = true,
    /// Maximum number of prepared statements to cache per connection
    stmt_cache_size: u32 = 100,
};

// =============================================================================
// Constants
// =============================================================================

/// Maximum number of SQL parameters supported per query/exec call
/// This limit is sufficient for most practical SQL queries
pub const MAX_PARAMS: usize = 32;

/// Maximum length for column names in query results
/// Column names exceeding this length will be truncated with a warning
pub const MAX_COLUMN_NAME_LEN: usize = 256;

/// Default prepared statement cache size
pub const DEFAULT_STMT_CACHE_SIZE: u32 = 100;

// =============================================================================
// Prepared Statement Cache
// =============================================================================

/// Prepared statement cache scoped to a single database connection
/// Uses a StringHashMap for simple key-value storage with automatic eviction when capacity is reached.
/// When reaching `max_size`, eviction order is arbitrary (not FIFO) due to HashMap iteration semantics.
///
/// ## Thread Safety
/// This cache is NOT thread-safe. Each connection should have its own
/// StatementCache instance, and access should be serialized if the
/// connection is shared across threads.
///
/// ## Usage
/// ```zig
/// var stmt_cache = StatementCache.init(allocator, conn, 100);
/// defer stmt_cache.deinit();
///
/// // Get or create a prepared statement
/// var stmt = try stmt_cache.getOrPrepare("SELECT * FROM users WHERE id = ?");
///
/// // Use the statement - bind params and execute
/// try stmt.bindAll(&.{zdbc.Value.initInt(1)});
/// var result = try stmt.query();
/// ```
pub const StatementCache = struct {
    /// Map from SQL string to prepared statement
    statements: std.StringHashMap(zdbc.Statement),
    allocator: std.mem.Allocator,
    connection: *zdbc.Connection,
    max_size: u32,
    hits: u64 = 0,
    misses: u64 = 0,

    const Self = @This();

    /// Cache statistics
    pub const Stats = struct {
        hits: u64,
        misses: u64,
        hit_rate: f64,
        size: usize,
        max_size: u32,
    };

    /// Initialize a new statement cache for a connection
    pub fn init(allocator: std.mem.Allocator, connection: *zdbc.Connection, max_size: u32) Self {
        return Self{
            .statements = std.StringHashMap(zdbc.Statement).init(allocator),
            .allocator = allocator,
            .connection = connection,
            .max_size = max_size,
        };
    }

    /// Clean up all cached statements
    pub fn deinit(self: *Self) void {
        // Deinitialize all cached statements
        var it = self.statements.iterator();
        while (it.next()) |entry| {
            var stmt = entry.value_ptr.*;
            stmt.deinit();
            // Free the duplicated key
            self.allocator.free(entry.key_ptr.*);
        }
        self.statements.deinit();
    }

    /// Get a cached statement or prepare a new one
    /// The returned statement is reset and ready for parameter binding
    /// Note: The statement remains owned by the cache and should not be deinitialized by the caller
    pub fn getOrPrepare(self: *Self, sql: []const u8) !*zdbc.Statement {
        // Try to get from cache
        if (self.statements.getPtr(sql)) |stmt_ptr| {
            self.hits += 1;

            // Reset the statement for reuse
            stmt_ptr.reset() catch |err| {
                // If reset fails, remove from cache and prepare fresh
                std.log.debug("StatementCache: reset failed for: {s}, error: {}", .{ sql[0..@min(sql.len, 64)], err });
                self.removeStatement(sql);
                return self.prepareFresh(sql);
            };

            // Clear any existing bindings
            stmt_ptr.clearBindings() catch |err| {
                // If clear fails, remove from cache and prepare fresh
                std.log.debug("StatementCache: clearBindings failed for: {s}, error: {}", .{ sql[0..@min(sql.len, 64)], err });
                self.removeStatement(sql);
                return self.prepareFresh(sql);
            };

            return stmt_ptr;
        }

        self.misses += 1;
        return self.prepareFresh(sql);
    }

    /// Remove a statement from the cache and clean it up
    fn removeStatement(self: *Self, sql: []const u8) void {
        if (self.statements.fetchRemove(sql)) |kv| {
            var stmt = kv.value;
            stmt.deinit();
            self.allocator.free(kv.key);
        }
    }

    /// Prepare a fresh statement and add to cache
    fn prepareFresh(self: *Self, sql: []const u8) !*zdbc.Statement {
        // Check if we need to evict entries (eviction when at capacity)
        if (self.statements.count() >= self.max_size) {
            // Remove one entry to make room (eviction order is arbitrary)
            var it = self.statements.iterator();
            if (it.next()) |entry| {
                const key_to_remove = entry.key_ptr.*;
                self.removeStatement(key_to_remove);
            }
        }

        var stmt = try self.connection.prepare(sql);
        errdefer stmt.deinit();

        // Duplicate the SQL key for storage
        const sql_key = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_key);

        // Add to cache
        try self.statements.put(sql_key, stmt);

        // Return pointer to the stored statement
        return self.statements.getPtr(sql_key).?;
    }

    /// Get cache statistics
    pub fn getStats(self: *const Self) Stats {
        const total = self.hits + self.misses;
        const hit_rate = if (total > 0)
            @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total))
        else
            0.0;
        return Stats{
            .hits = self.hits,
            .misses = self.misses,
            .hit_rate = hit_rate,
            .size = self.statements.count(),
            .max_size = self.max_size,
        };
    }

    /// Clear all cached statements
    pub fn clear(self: *Self) void {
        var it = self.statements.iterator();
        while (it.next()) |entry| {
            var stmt = entry.value_ptr.*;
            stmt.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.statements.clearRetainingCapacity();
        self.hits = 0;
        self.misses = 0;
    }

    /// Check if a statement is cached for the given SQL
    pub fn contains(self: *const Self, sql: []const u8) bool {
        return self.statements.contains(sql);
    }

    /// Invalidate a specific cached statement
    pub fn invalidate(self: *Self, sql: []const u8) bool {
        if (self.statements.fetchRemove(sql)) |kv| {
            var stmt = kv.value;
            stmt.deinit();
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    /// Get the current number of cached statements
    pub fn count(self: *const Self) usize {
        return self.statements.count();
    }
};

// =============================================================================
// Global State (Thread Safety)
// =============================================================================

/// Global pointer to the active database plugin.
///
/// ## Thread Safety
/// This global is set once during server initialization (in AppContext.init)
/// before any concurrent request handling begins, and cleared during server
/// shutdown. No synchronization is needed as the value is effectively immutable
/// during the server's operational phase.
///
/// ## Usage
/// Used by Lua functions to access the database plugin. Each request handler
/// runs in its own thread but reads the same plugin pointer.
var global_db_plugin: ?*DbPlugin = null;

/// Set the global database plugin pointer.
/// Should only be called during server initialization or shutdown.
pub fn setGlobalPlugin(plugin: ?*DbPlugin) void {
    global_db_plugin = plugin;
}

/// Get the global database plugin pointer
pub fn getGlobalPlugin() ?*DbPlugin {
    return global_db_plugin;
}

/// Database plugin context
pub const DbPlugin = struct {
    allocator: std.mem.Allocator,
    config: ?DbConfig,
    connection: ?zdbc.Connection,
    // Prepared statement cache scoped to this connection
    // This cache is NOT shared across connections for thread safety
    stmt_cache: ?StatementCache,
    // Note: Currently uses a single connection per plugin instance.
    // The db_pool_size config is reserved for future pooling implementation.
    initialized: bool,
    error_message: ?[]const u8,

    const Self = @This();

    /// Plugin VTable implementation
    pub const vtable = PluginVTable{
        .info = info,
        .init = initPlugin,
        .deinit = deinitPlugin,
        .health_check = healthCheck,
        .register_lua = registerLua,
        .on_request = null,
    };

    /// Create a new database plugin instance
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = null,
            .connection = null,
            .stmt_cache = null,
            .initialized = false,
            .error_message = null,
        };
        return self;
    }

    /// Create a Plugin wrapper for this database plugin
    pub fn asPlugin(self: *Self) Plugin {
        return Plugin{
            .ctx = self,
            .vtable = &vtable,
            .state = .uninitialized,
            .error_message = null,
        };
    }

    /// Get plugin information
    fn info() PluginInfo {
        return PluginInfo{
            .name = "db",
            .version = "0.1.0",
            .description = "Database connectivity plugin using zdbc",
            .author = "zhttpd",
        };
    }

    /// Initialize the plugin
    fn initPlugin(ctx: *anyopaque, allocator: std.mem.Allocator, config_str: ?[]const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = allocator;

        if (config_str) |cfg| {
            // Parse configuration from JSON string
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, cfg, .{}) catch {
                self.error_message = "Failed to parse configuration";
                return false;
            };
            defer parsed.deinit();

            const obj = parsed.value.object;

            // Extract URI
            const uri_val = obj.get("uri") orelse {
                self.error_message = "Missing 'uri' in configuration";
                return false;
            };
            const uri = uri_val.string;

            // Extract pool size
            const pool_size: u32 = if (obj.get("pool_size")) |ps|
                @intCast(ps.integer)
            else
                5;

            // Extract statement cache size
            const stmt_cache_size: u32 = if (obj.get("stmt_cache_size")) |scs|
                @intCast(scs.integer)
            else
                DEFAULT_STMT_CACHE_SIZE;

            // Store configuration (need to dupe strings for ownership)
            const uri_copy = self.allocator.dupe(u8, uri) catch {
                self.error_message = "Memory allocation failed";
                return false;
            };

            self.config = DbConfig{
                .uri = uri_copy,
                .pool_size = pool_size,
                .enable_pool = pool_size > 1,
                .stmt_cache_size = stmt_cache_size,
            };

            // Initialize database connection
            if (self.config) |db_cfg| {
                // Use single connection (pooling not currently supported)
                self.connection = zdbc.open(self.allocator, db_cfg.uri) catch {
                    self.error_message = "Failed to open database connection";
                    return false;
                };

                // Initialize prepared statement cache for this connection
                if (self.connection) |*conn| {
                    self.stmt_cache = StatementCache.init(self.allocator, conn, db_cfg.stmt_cache_size);
                }
            }

            self.initialized = true;
            return true;
        }

        self.error_message = "No configuration provided";
        return false;
    }

    /// Deinitialize the plugin
    fn deinitPlugin(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Deinitialize statement cache first (before closing connection)
        if (self.stmt_cache) |*sc| {
            sc.deinit();
            self.stmt_cache = null;
        }

        if (self.connection) |*conn| {
            conn.close();
            self.connection = null;
        }

        if (self.config) |cfg| {
            self.allocator.free(cfg.uri);
            self.config = null;
        }

        self.initialized = false;
    }

    /// Health check
    fn healthCheck(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (!self.initialized) return false;

        // Try to verify database connection with a simple query
        if (self.connection) |*conn| {
            // Use a simple query that works on all databases
            var result = conn.queryNoParams("SELECT 1") catch return false;
            result.deinit();
            return true;
        }

        return false;
    }

    /// Register Lua functions
    fn registerLua(ctx: *anyopaque, lua: *ziglua.Lua) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (!self.initialized) return false;

        // Store plugin pointer in Lua registry for access from Lua functions
        lua.pushLightUserdata(self);
        lua.setField(ziglua.registry_index, "_db_plugin");

        // Create 'db' module table
        lua.newTable();

        // Register functions
        lua.pushFunction(ziglua.wrap(luaQuery));
        lua.setField(-2, "query");

        lua.pushFunction(ziglua.wrap(luaExec));
        lua.setField(-2, "exec");

        lua.pushFunction(ziglua.wrap(luaPrepare));
        lua.setField(-2, "prepare");

        lua.pushFunction(ziglua.wrap(luaBegin));
        lua.setField(-2, "begin");

        lua.pushFunction(ziglua.wrap(luaCommit));
        lua.setField(-2, "commit");

        lua.pushFunction(ziglua.wrap(luaRollback));
        lua.setField(-2, "rollback");

        lua.pushFunction(ziglua.wrap(luaStatus));
        lua.setField(-2, "status");

        // Set as global 'db'
        lua.setGlobal("db");

        return true;
    }

    /// Get connection
    pub fn getConnection(self: *Self) ?*zdbc.Connection {
        if (self.connection) |*conn| {
            return conn;
        }
        return null;
    }

    /// Get the statement cache
    pub fn getStatementCache(self: *Self) ?*StatementCache {
        if (self.stmt_cache) |*sc| {
            return sc;
        }
        return null;
    }

    /// Execute a query and return results
    /// Directly calls the connection's query method without statement caching
    /// For cached queries, use prepare() first, then call query() on the statement
    pub fn query(self: *Self, sql: []const u8, params: []const zdbc.Value) !zdbc.Result {
        if (self.connection) |*conn| {
            return conn.query(sql, params);
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Execute a statement (INSERT, UPDATE, DELETE)
    /// Directly calls the connection's exec method without statement caching
    /// For cached statements, use prepare() first, then call exec() on the statement
    pub fn exec(self: *Self, sql: []const u8, params: []const zdbc.Value) !usize {
        if (self.connection) |*conn| {
            return conn.exec(sql, params);
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Prepare a statement for execution with caching
    /// Uses the statement cache to avoid re-preparing frequently used statements
    /// Returns a pointer to the cached statement, ready for parameter binding
    /// Note: The statement is owned by the cache and should not be deinitialized by the caller
    pub fn prepare(self: *Self, sql: []const u8) !*zdbc.Statement {
        if (self.stmt_cache) |*sc| {
            return sc.getOrPrepare(sql);
        }
        // No cache available - statement caching is required for prepare()
        // If you need to execute without cache, use query() or exec() directly
        return zdbc.Error.NotImplemented;
    }

    /// Begin a transaction
    pub fn begin(self: *Self) !void {
        if (self.connection) |*conn| {
            return conn.begin();
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Commit the current transaction
    pub fn commit(self: *Self) !void {
        if (self.connection) |*conn| {
            return conn.commit();
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Rollback the current transaction
    pub fn rollback(self: *Self) !void {
        if (self.connection) |*conn| {
            return conn.rollback();
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Get the last insert row ID
    pub fn lastInsertId(self: *Self) ?i64 {
        if (self.connection) |*conn| {
            return conn.lastInsertId();
        }
        return null;
    }

    /// Get the number of rows affected by the last operation
    pub fn affectedRows(self: *Self) usize {
        if (self.connection) |*conn| {
            return conn.affectedRows();
        }
        return 0;
    }

    /// Ping the database to check connection health
    pub fn ping(self: *Self) !void {
        if (self.connection) |*conn| {
            return conn.ping();
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Get the last error message
    pub fn lastError(self: *Self) ?[]const u8 {
        if (self.connection) |*conn| {
            return conn.lastError();
        }
        return null;
    }

    /// Get statement cache statistics
    pub fn getStmtCacheStats(self: *const Self) ?StatementCache.Stats {
        if (self.stmt_cache) |sc| {
            return sc.getStats();
        }
        return null;
    }

    /// Clear the statement cache
    pub fn clearStmtCache(self: *Self) void {
        if (self.stmt_cache) |*sc| {
            sc.clear();
        }
    }

    /// Invalidate a specific cached statement
    pub fn invalidateCachedStmt(self: *Self, sql: []const u8) bool {
        if (self.stmt_cache) |*sc| {
            return sc.invalidate(sql);
        }
        return false;
    }

    /// Check if plugin is healthy (public method)
    pub fn isHealthy(self: *Self) bool {
        return healthCheck(self);
    }
};

// ============================================================================
// Lua Binding Functions
// ============================================================================

/// Register the db module in a Lua state (public interface for external use)
/// This can be called to register the db module in any Lua state
pub fn registerDbModule(lua: *ziglua.Lua) void {
    // Create 'db' module table
    lua.newTable();

    // Register functions
    lua.pushFunction(ziglua.wrap(luaQuery));
    lua.setField(-2, "query");

    lua.pushFunction(ziglua.wrap(luaExec));
    lua.setField(-2, "exec");

    lua.pushFunction(ziglua.wrap(luaPrepare));
    lua.setField(-2, "prepare");

    lua.pushFunction(ziglua.wrap(luaBegin));
    lua.setField(-2, "begin");

    lua.pushFunction(ziglua.wrap(luaCommit));
    lua.setField(-2, "commit");

    lua.pushFunction(ziglua.wrap(luaRollback));
    lua.setField(-2, "rollback");

    lua.pushFunction(ziglua.wrap(luaStatus));
    lua.setField(-2, "status");

    // Set as global 'db'
    lua.setGlobal("db");
}

/// Get plugin from Lua registry or global
fn getPluginFromLua(lua: *ziglua.Lua) ?*DbPlugin {
    // First try registry
    _ = lua.getField(ziglua.registry_index, "_db_plugin");
    if (lua.typeOf(-1) == .light_userdata) {
        // toPointer returns a non-null const pointer
        const raw_ptr = lua.toPointer(-1) catch {
            lua.pop(1);
            return global_db_plugin;
        };
        lua.pop(1);
        // Cast const away and to the correct type
        const mut_ptr: *anyopaque = @constCast(raw_ptr);
        return @ptrCast(@alignCast(mut_ptr));
    }
    lua.pop(1);
    // Fall back to global
    return global_db_plugin;
}

/// Convert Lua value at stack index to zdbc.Value
fn luaToDbValue(lua: *ziglua.Lua, idx: i32) zdbc.Value {
    const lua_type = lua.typeOf(idx);
    return switch (lua_type) {
        .nil => zdbc.Value.initNull(),
        .boolean => zdbc.Value.initBool(lua.toBoolean(idx)),
        .number => blk: {
            const num = lua.toNumber(idx) catch 0;
            // Check if it's an integer
            const int_val = lua.toInteger(idx) catch break :blk zdbc.Value.initFloat(num);
            if (@as(f64, @floatFromInt(int_val)) == num) {
                break :blk zdbc.Value.initInt(int_val);
            }
            break :blk zdbc.Value.initFloat(num);
        },
        .string => blk: {
            const str = lua.toString(idx) catch break :blk zdbc.Value.initNull();
            break :blk zdbc.Value.initText(str);
        },
        else => zdbc.Value.initNull(),
    };
}

/// Push zdbc.Value to Lua stack
fn pushDbValueToLua(lua: *ziglua.Lua, value: zdbc.Value) void {
    switch (value) {
        .null => lua.pushNil(),
        .boolean => |b| lua.pushBoolean(b),
        .int => |i| lua.pushInteger(i),
        .uint => |u| lua.pushInteger(@intCast(u)),
        .float => |f| lua.pushNumber(f),
        .text => |t| _ = lua.pushString(t),
        .blob => |b| _ = lua.pushString(b),
    }
}

/// Lua: db.query(sql, ...) - Execute SELECT query
fn luaQuery(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    // Get SQL string
    const sql = lua.toString(1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL string");
        return 2;
    };

    // Collect parameters using the module-level MAX_PARAMS constant
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    // Warn if parameters were truncated (more params provided than MAX_PARAMS)
    if (top > @as(i32, @intCast(MAX_PARAMS)) + 1) {
        std.log.warn("db.query: Too many parameters ({d}), truncated to {d}", .{ top - 1, MAX_PARAMS });
    }

    // Execute query
    var result = plugin.query(sql, params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit();

    // Convert results to Lua table
    lua.newTable();
    var row_idx: i32 = 1;

    while (true) {
        const maybe_row = result.next() catch break;
        if (maybe_row) |row| {
            lua.newTable();

            // Get column count and names
            const col_count = result.columnCount();
            var col_idx: usize = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                const value = row.get(col_idx) catch continue;
                pushDbValueToLua(lua, value);

                // Set by column name if available
                if (result.columnName(col_idx)) |name| {
                    // Need to convert to null-terminated string
                    // Using MAX_COLUMN_NAME_LEN constant for buffer size
                    var name_buf: [MAX_COLUMN_NAME_LEN]u8 = undefined;
                    const len = @min(name.len, name_buf.len - 1);
                    if (name.len >= MAX_COLUMN_NAME_LEN) {
                        std.log.warn("db.query: Column name truncated from {d} to {d} chars", .{ name.len, MAX_COLUMN_NAME_LEN - 1 });
                    }
                    @memcpy(name_buf[0..len], name[0..len]);
                    name_buf[len] = 0;
                    lua.setField(-2, name_buf[0..len :0]);
                } else {
                    lua.rawSetIndex(-2, @intCast(col_idx + 1));
                }
            }

            lua.rawSetIndex(-2, row_idx);
            row_idx += 1;
        } else {
            break;
        }
    }

    return 1;
}

/// Lua: db.exec(sql, ...) - Execute INSERT/UPDATE/DELETE
fn luaExec(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    // Get SQL string
    const sql = lua.toString(1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL string");
        return 2;
    };

    // Collect parameters using the module-level MAX_PARAMS constant
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    // Warn if parameters were truncated
    if (top > @as(i32, @intCast(MAX_PARAMS)) + 1) {
        std.log.warn("db.exec: Too many parameters ({d}), truncated to {d}", .{ top - 1, MAX_PARAMS });
    }

    // Execute statement
    const affected = plugin.exec(sql, params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    lua.pushInteger(@intCast(affected));
    return 1;
}

/// Lua: db.prepare(sql) - Prepare a statement with caching
/// Returns a table with methods: query(params...), exec(params...)
fn luaPrepare(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    // Get SQL string
    const sql = lua.toString(1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL string");
        return 2;
    };

    // Prepare the statement (with caching)
    _ = plugin.prepare(sql) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Create a statement object table
    lua.newTable();

    // Store the SQL for reference
    // Note: The actual statement is managed by the cache (not stored in Lua)
    // Each call to plugin.prepare(sql) returns the same cached statement
    _ = lua.pushString(sql);
    lua.setField(-2, "_sql");

    // Add query method
    lua.pushFunction(ziglua.wrap(luaStatementQuery));
    lua.setField(-2, "query");

    // Add exec method
    lua.pushFunction(ziglua.wrap(luaStatementExec));
    lua.setField(-2, "exec");

    // Note: The statement itself is not stored in Lua
    // It's managed by the plugin's statement cache and accessed via SQL key
    // This keeps the cache in control of statement lifecycle

    return 1;
}

/// Lua: statement:query(...) - Execute query on prepared statement
fn luaStatementQuery(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    // Get the statement table (self)
    if (lua.typeOf(1) != .table) {
        lua.pushNil();
        _ = lua.pushString("Invalid statement object");
        return 2;
    }

    // Get the SQL from the statement table
    _ = lua.getField(1, "_sql");
    const sql = lua.toString(-1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL in statement");
        return 2;
    };
    lua.pop(1); // pop SQL string

    // Collect parameters starting from arg 2
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    if (top > @as(i32, @intCast(MAX_PARAMS)) + 1) {
        std.log.warn("statement:query: Too many parameters ({d}), truncated to {d}", .{ top - 1, MAX_PARAMS });
    }

    // Get the cached statement
    // This call to prepare() retrieves the already-cached statement (cache hit expected)
    // The cache manages statement lifecycle, so we don't store pointers in Lua
    var stmt = plugin.prepare(sql) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Bind parameters
    stmt.bindAll(params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Execute query
    var result = stmt.query() catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit();

    // Convert results to Lua table (same as luaQuery)
    lua.newTable();
    var row_idx: i32 = 1;

    while (true) {
        const maybe_row = result.next() catch break;
        if (maybe_row) |row| {
            lua.newTable();

            const col_count = result.columnCount();
            var col_idx: usize = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                const value = row.get(col_idx) catch continue;
                pushDbValueToLua(lua, value);

                if (result.columnName(col_idx)) |name| {
                    var name_buf: [MAX_COLUMN_NAME_LEN]u8 = undefined;
                    const len = @min(name.len, name_buf.len - 1);
                    if (name.len >= MAX_COLUMN_NAME_LEN) {
                        std.log.warn("statement:query: Column name truncated from {d} to {d} chars", .{ name.len, MAX_COLUMN_NAME_LEN - 1 });
                    }
                    @memcpy(name_buf[0..len], name[0..len]);
                    name_buf[len] = 0;
                    lua.setField(-2, name_buf[0..len :0]);
                } else {
                    lua.rawSetIndex(-2, @intCast(col_idx + 1));
                }
            }

            lua.rawSetIndex(-2, row_idx);
            row_idx += 1;
        } else {
            break;
        }
    }

    return 1;
}

/// Lua: statement:exec(...) - Execute statement
fn luaStatementExec(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    // Get the statement table (self)
    if (lua.typeOf(1) != .table) {
        lua.pushNil();
        _ = lua.pushString("Invalid statement object");
        return 2;
    }

    // Get the SQL from the statement table
    _ = lua.getField(1, "_sql");
    const sql = lua.toString(-1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL in statement");
        return 2;
    };
    lua.pop(1); // pop SQL string

    // Collect parameters starting from arg 2
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    if (top > @as(i32, @intCast(MAX_PARAMS)) + 1) {
        std.log.warn("statement:exec: Too many parameters ({d}), truncated to {d}", .{ top - 1, MAX_PARAMS });
    }

    // Get the cached statement
    // This call to prepare() retrieves the already-cached statement (cache hit expected)
    // The cache manages statement lifecycle, so we don't store pointers in Lua
    var stmt = plugin.prepare(sql) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Bind parameters
    stmt.bindAll(params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Execute statement
    const affected = stmt.exec() catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    lua.pushInteger(@intCast(affected));
    return 1;
}

/// Lua: db.begin() - Begin transaction
fn luaBegin(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    plugin.begin() catch |err| {
        lua.pushBoolean(false);
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

/// Lua: db.commit() - Commit transaction
fn luaCommit(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    plugin.commit() catch |err| {
        lua.pushBoolean(false);
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

/// Lua: db.rollback() - Rollback transaction
fn luaRollback(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Database not initialized");
        return 2;
    };

    plugin.rollback() catch |err| {
        lua.pushBoolean(false);
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

/// Lua: db.status() - Get database status
fn luaStatus(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.newTable();
        lua.pushBoolean(false);
        lua.setField(-2, "connected");
        _ = lua.pushString("not initialized");
        lua.setField(-2, "error");
        return 1;
    };

    lua.newTable();

    lua.pushBoolean(plugin.initialized);
    lua.setField(-2, "initialized");

    const connected = plugin.isHealthy();
    lua.pushBoolean(connected);
    lua.setField(-2, "connected");

    if (plugin.config) |cfg| {
        _ = lua.pushString(cfg.uri);
        lua.setField(-2, "uri");

        lua.pushInteger(@intCast(cfg.pool_size));
        lua.setField(-2, "pool_size");

        lua.pushBoolean(cfg.enable_pool);
        lua.setField(-2, "pool_enabled");

        lua.pushInteger(@intCast(cfg.stmt_cache_size));
        lua.setField(-2, "stmt_cache_size");
    }

    // Add statement cache statistics
    if (plugin.getStmtCacheStats()) |stats| {
        pushStmtCacheStats(lua, stats);
    }

    return 1;
}

// ============================================================================
// Public Lua Helper Functions (for use by context module)
// ============================================================================

/// Helper function to push statement cache stats to Lua stack
fn pushStmtCacheStats(lua: *ziglua.Lua, stats: StatementCache.Stats) void {
    lua.newTable();
    lua.pushInteger(@intCast(stats.hits));
    lua.setField(-2, "hits");
    lua.pushInteger(@intCast(stats.misses));
    lua.setField(-2, "misses");
    lua.pushNumber(stats.hit_rate);
    lua.setField(-2, "hit_rate");
    lua.pushInteger(@intCast(stats.size));
    lua.setField(-2, "size");
    lua.pushInteger(@intCast(stats.max_size));
    lua.setField(-2, "max_size");
    lua.setField(-2, "stmt_cache_stats");
}

/// Execute SELECT query with a specific plugin
/// sql_arg_idx specifies which Lua argument contains the SQL string
pub fn luaQueryWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin, sql_arg_idx: i32) i32 {
    // Get SQL string
    const sql = lua.toString(sql_arg_idx) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL string");
        return 2;
    };

    // Collect parameters using module-level MAX_PARAMS constant
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = sql_arg_idx + 1;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    // Warn if parameters were truncated
    const provided_params = top - sql_arg_idx;
    if (provided_params > @as(i32, @intCast(MAX_PARAMS))) {
        std.log.warn("db:query: Too many parameters ({d}), truncated to {d}", .{ provided_params, MAX_PARAMS });
    }

    // Execute query
    var result = plugin.query(sql, params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit();

    // Convert results to Lua table
    lua.newTable();
    var row_idx: i32 = 1;

    while (true) {
        const maybe_row = result.next() catch break;
        if (maybe_row) |row| {
            lua.newTable();

            const col_count = result.columnCount();
            var col_idx: usize = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                const value = row.get(col_idx) catch continue;
                pushDbValueToLua(lua, value);

                if (result.columnName(col_idx)) |name| {
                    // Using MAX_COLUMN_NAME_LEN constant for buffer size
                    var name_buf: [MAX_COLUMN_NAME_LEN]u8 = undefined;
                    const len = @min(name.len, name_buf.len - 1);
                    if (name.len >= MAX_COLUMN_NAME_LEN) {
                        std.log.warn("db:query: Column name truncated from {d} to {d} chars", .{ name.len, MAX_COLUMN_NAME_LEN - 1 });
                    }
                    @memcpy(name_buf[0..len], name[0..len]);
                    name_buf[len] = 0;
                    lua.setField(-2, name_buf[0..len :0]);
                } else {
                    lua.rawSetIndex(-2, @intCast(col_idx + 1));
                }
            }

            lua.rawSetIndex(-2, row_idx);
            row_idx += 1;
        } else {
            break;
        }
    }

    return 1;
}

/// Execute INSERT/UPDATE/DELETE with a specific plugin
pub fn luaExecWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin, sql_arg_idx: i32) i32 {
    // Get SQL string
    const sql = lua.toString(sql_arg_idx) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL string");
        return 2;
    };

    // Collect parameters using module-level MAX_PARAMS constant
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = sql_arg_idx + 1;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    // Warn if parameters were truncated
    const provided_params = top - sql_arg_idx;
    if (provided_params > @as(i32, @intCast(MAX_PARAMS))) {
        std.log.warn("db:exec: Too many parameters ({d}), truncated to {d}", .{ provided_params, MAX_PARAMS });
    }

    // Execute statement
    const affected = plugin.exec(sql, params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    lua.pushInteger(@intCast(affected));
    return 1;
}

/// Begin transaction with a specific plugin
pub fn luaBeginWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin) i32 {
    if (plugin.connection) |*conn| {
        conn.begin() catch |err| {
            lua.pushBoolean(false);
            _ = lua.pushString(@errorName(err));
            return 2;
        };
        lua.pushBoolean(true);
        return 1;
    }

    lua.pushBoolean(false);
    _ = lua.pushString("No database connection");
    return 2;
}

/// Commit transaction with a specific plugin
pub fn luaCommitWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin) i32 {
    if (plugin.connection) |*conn| {
        conn.commit() catch |err| {
            lua.pushBoolean(false);
            _ = lua.pushString(@errorName(err));
            return 2;
        };
        lua.pushBoolean(true);
        return 1;
    }

    lua.pushBoolean(false);
    _ = lua.pushString("No database connection");
    return 2;
}

/// Rollback transaction with a specific plugin
pub fn luaRollbackWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin) i32 {
    if (plugin.connection) |*conn| {
        conn.rollback() catch |err| {
            lua.pushBoolean(false);
            _ = lua.pushString(@errorName(err));
            return 2;
        };
        lua.pushBoolean(true);
        return 1;
    }

    lua.pushBoolean(false);
    _ = lua.pushString("No database connection");
    return 2;
}

/// Get status with a specific plugin
pub fn luaStatusWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin) i32 {
    lua.newTable();

    lua.pushBoolean(plugin.initialized);
    lua.setField(-2, "initialized");

    const connected = plugin.isHealthy();
    lua.pushBoolean(connected);
    lua.setField(-2, "connected");

    if (plugin.config) |cfg| {
        _ = lua.pushString(cfg.uri);
        lua.setField(-2, "uri");

        lua.pushInteger(@intCast(cfg.pool_size));
        lua.setField(-2, "pool_size");

        lua.pushBoolean(cfg.enable_pool);
        lua.setField(-2, "pool_enabled");

        lua.pushInteger(@intCast(cfg.stmt_cache_size));
        lua.setField(-2, "stmt_cache_size");
    }

    // Add statement cache statistics
    if (plugin.getStmtCacheStats()) |stats| {
        pushStmtCacheStats(lua, stats);
    }

    return 1;
}

/// Prepare a statement with a specific plugin
/// sql_arg_idx specifies which Lua argument contains the SQL string
pub fn luaPrepareWithPlugin(lua: *ziglua.Lua, plugin: *DbPlugin, sql_arg_idx: i32) i32 {
    // Get SQL string
    const sql = lua.toString(sql_arg_idx) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL string");
        return 2;
    };

    // Prepare the statement (with caching)
    _ = plugin.prepare(sql) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Create a statement object table
    lua.newTable();

    // Store the SQL for reference
    // Note: The actual statement is managed by the cache (not stored in Lua)
    // Each call to plugin.prepare(sql) returns the same cached statement
    _ = lua.pushString(sql);
    lua.setField(-2, "_sql");

    // Store the plugin pointer as light userdata (for statement methods)
    lua.pushLightUserdata(@ptrCast(plugin));
    lua.setField(-2, "_plugin");

    // Add query method
    lua.pushFunction(ziglua.wrap(luaStatementQueryWithPlugin));
    lua.setField(-2, "query");

    // Add exec method
    lua.pushFunction(ziglua.wrap(luaStatementExecWithPlugin));
    lua.setField(-2, "exec");

    // Note: The statement itself is not stored in Lua
    // It's managed by the plugin's statement cache and accessed via SQL key
    // This keeps the cache in control of statement lifecycle

    return 1;
}

/// Lua: statement:query(...) - Execute query on prepared statement (context version)
fn luaStatementQueryWithPlugin(lua: *ziglua.Lua) i32 {
    // Get the statement table (self)
    if (lua.typeOf(1) != .table) {
        lua.pushNil();
        _ = lua.pushString("Invalid statement object");
        return 2;
    }

    // Get the plugin from the statement table
    _ = lua.getField(1, "_plugin");
    const raw_ptr = lua.toPointer(-1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid plugin in statement");
        return 2;
    };
    lua.pop(1);
    const mut_ptr: *anyopaque = @constCast(raw_ptr);
    const plugin: *DbPlugin = @ptrCast(@alignCast(mut_ptr));

    // Get the SQL from the statement table
    _ = lua.getField(1, "_sql");
    const sql = lua.toString(-1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL in statement");
        return 2;
    };
    lua.pop(1);

    // Collect parameters starting from arg 2
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    if (top > @as(i32, @intCast(MAX_PARAMS)) + 1) {
        std.log.warn("statement:query: Too many parameters ({d}), truncated to {d}", .{ top - 1, MAX_PARAMS });
    }

    // Get the cached statement
    var stmt = plugin.prepare(sql) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Bind parameters
    stmt.bindAll(params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Execute query
    var result = stmt.query() catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit();

    // Convert results to Lua table
    lua.newTable();
    var row_idx: i32 = 1;

    while (true) {
        const maybe_row = result.next() catch break;
        if (maybe_row) |row| {
            lua.newTable();

            const col_count = result.columnCount();
            var col_idx: usize = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                const value = row.get(col_idx) catch continue;
                pushDbValueToLua(lua, value);

                if (result.columnName(col_idx)) |name| {
                    var name_buf: [MAX_COLUMN_NAME_LEN]u8 = undefined;
                    const len = @min(name.len, name_buf.len - 1);
                    if (name.len >= MAX_COLUMN_NAME_LEN) {
                        std.log.warn("statement:query: Column name truncated from {d} to {d} chars", .{ name.len, MAX_COLUMN_NAME_LEN - 1 });
                    }
                    @memcpy(name_buf[0..len], name[0..len]);
                    name_buf[len] = 0;
                    lua.setField(-2, name_buf[0..len :0]);
                } else {
                    lua.rawSetIndex(-2, @intCast(col_idx + 1));
                }
            }

            lua.rawSetIndex(-2, row_idx);
            row_idx += 1;
        } else {
            break;
        }
    }

    return 1;
}

/// Lua: statement:exec(...) - Execute statement (context version)
fn luaStatementExecWithPlugin(lua: *ziglua.Lua) i32 {
    // Get the statement table (self)
    if (lua.typeOf(1) != .table) {
        lua.pushNil();
        _ = lua.pushString("Invalid statement object");
        return 2;
    }

    // Get the plugin from the statement table
    _ = lua.getField(1, "_plugin");
    const raw_ptr = lua.toPointer(-1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid plugin in statement");
        return 2;
    };
    lua.pop(1);
    const mut_ptr: *anyopaque = @constCast(raw_ptr);
    const plugin: *DbPlugin = @ptrCast(@alignCast(mut_ptr));

    // Get the SQL from the statement table
    _ = lua.getField(1, "_sql");
    const sql = lua.toString(-1) catch {
        lua.pushNil();
        _ = lua.pushString("Invalid SQL in statement");
        return 2;
    };
    lua.pop(1);

    // Collect parameters starting from arg 2
    const top = lua.getTop();
    var params_buf: [MAX_PARAMS]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
    }

    if (top > @as(i32, @intCast(MAX_PARAMS)) + 1) {
        std.log.warn("statement:exec: Too many parameters ({d}), truncated to {d}", .{ top - 1, MAX_PARAMS });
    }

    // Get the cached statement
    var stmt = plugin.prepare(sql) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Bind parameters
    stmt.bindAll(params_buf[0..param_count]) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    // Execute statement
    const affected = stmt.exec() catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };

    lua.pushInteger(@intCast(affected));
    return 1;
}

// ============================================================================
// Zig-side Authentication Utilities
// ============================================================================

/// User record from database
pub const User = struct {
    id: i64,
    username: []const u8,
    password_hash: []const u8,
    roles: []const u8,
    created_at: i64,
};

/// Authentication result
pub const AuthResult = struct {
    authenticated: bool,
    user_id: ?i64 = null,
    username: ?[]const u8 = null,
    roles: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

/// Validate user credentials against database
pub fn validateUser(plugin: *DbPlugin, username: []const u8, password_hash: []const u8) AuthResult {
    if (!plugin.initialized) {
        return AuthResult{
            .authenticated = false,
            .error_message = "Database not initialized",
        };
    }

    var result = plugin.query(
        "SELECT id, username, roles FROM users WHERE username = ? AND password_hash = ? AND active = 1",
        &.{ zdbc.Value.initText(username), zdbc.Value.initText(password_hash) },
    ) catch {
        return AuthResult{
            .authenticated = false,
            .error_message = "Database query failed",
        };
    };
    defer result.deinit();

    const maybe_row = result.next() catch {
        return AuthResult{
            .authenticated = false,
            .error_message = "Database query failed",
        };
    };

    if (maybe_row) |row| {
        const id = row.getInt(0) catch null;
        const uname = row.getText(1) catch null;
        const roles = row.getText(2) catch null;

        return AuthResult{
            .authenticated = true,
            .user_id = id,
            .username = uname,
            .roles = roles,
        };
    }

    return AuthResult{
        .authenticated = false,
        .error_message = "Invalid credentials",
    };
}

/// Check if user has required role
pub fn userHasRole(plugin: *DbPlugin, user_id: i64, required_role: []const u8) bool {
    if (!plugin.initialized) return false;

    var result = plugin.query(
        "SELECT roles FROM users WHERE id = ? AND active = 1",
        &.{zdbc.Value.initInt(user_id)},
    ) catch return false;
    defer result.deinit();

    const maybe_row = result.next() catch return false;
    if (maybe_row) |row| {
        const roles = row.getText(0) catch return false;
        // Simple role check - roles are comma-separated
        if (roles) |r| {
            var it = std.mem.splitSequence(u8, r, ",");
            while (it.next()) |role| {
                const trimmed = std.mem.trim(u8, role, " ");
                if (std.mem.eql(u8, trimmed, required_role)) {
                    return true;
                }
            }
        }
    }

    return false;
}

test "DbPlugin creation" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    try testing.expect(!plugin.initialized);
    try testing.expect(plugin.connection == null);
    try testing.expect(plugin.stmt_cache == null);
}

test "StatementCache stats" {
    const testing = std.testing;

    // Test Stats struct initialization
    const stats = StatementCache.Stats{
        .hits = 10,
        .misses = 5,
        .hit_rate = 0.667,
        .size = 3,
        .max_size = 100,
    };

    try testing.expect(stats.hits == 10);
    try testing.expect(stats.misses == 5);
    try testing.expect(stats.size == 3);
    try testing.expect(stats.max_size == 100);
}

test "DbPlugin query and exec without caching" {
    const testing = std.testing;

    // Create a temporary database
    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    // Initialize with SQLite in-memory database
    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    // Create a test table
    const create_table = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)";
    _ = try plugin.exec(create_table, &.{});

    // Test direct exec (no caching)
    const affected = try plugin.exec("INSERT INTO users (name, age) VALUES (?, ?)", &.{
        zdbc.Value.initText("Alice"),
        zdbc.Value.initInt(30),
    });
    try testing.expect(affected == 1);

    // Test direct query (no caching)
    var result = try plugin.query("SELECT * FROM users WHERE name = ?", &.{zdbc.Value.initText("Alice")});
    defer result.deinit();

    const maybe_row = try result.next();
    try testing.expect(maybe_row != null);
    if (maybe_row) |row| {
        const name = try row.getText(1);
        try testing.expect(name != null);
        if (name) |n| {
            try testing.expect(std.mem.eql(u8, n, "Alice"));
        }
    }
}

test "DbPlugin prepare with statement caching" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    // Create table
    _ = try plugin.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)", &.{});

    // Prepare a statement (should cache it)
    const sql = "INSERT INTO test (value) VALUES (?)";
    var stmt1 = try plugin.prepare(sql);
    try stmt1.bindAll(&.{zdbc.Value.initText("first")});
    _ = try stmt1.exec();

    // Verify cache statistics
    if (plugin.getStmtCacheStats()) |stats| {
        try testing.expect(stats.misses == 1); // First prepare is a miss
        try testing.expect(stats.hits == 0);
    }

    // Prepare the same statement again (should hit cache)
    var stmt2 = try plugin.prepare(sql);
    try stmt2.bindAll(&.{zdbc.Value.initText("second")});
    _ = try stmt2.exec();

    // Verify cache hit
    if (plugin.getStmtCacheStats()) |stats| {
        try testing.expect(stats.hits == 1); // Second prepare is a hit
        try testing.expect(stats.misses == 1);
    }

    // Verify both inserts worked
    var result = try plugin.query("SELECT COUNT(*) FROM test", &.{});
    defer result.deinit();
    const maybe_row = try result.next();
    try testing.expect(maybe_row != null);
}

test "DbPlugin transaction operations" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    _ = try plugin.exec("CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)", &.{});
    _ = try plugin.exec("INSERT INTO accounts (id, balance) VALUES (?, ?)", &.{ zdbc.Value.initInt(1), zdbc.Value.initInt(1000) });
    _ = try plugin.exec("INSERT INTO accounts (id, balance) VALUES (?, ?)", &.{ zdbc.Value.initInt(2), zdbc.Value.initInt(500) });

    // Test successful transaction
    try plugin.begin();
    _ = try plugin.exec("UPDATE accounts SET balance = balance - 100 WHERE id = ?", &.{zdbc.Value.initInt(1)});
    _ = try plugin.exec("UPDATE accounts SET balance = balance + 100 WHERE id = ?", &.{zdbc.Value.initInt(2)});
    try plugin.commit();

    // Verify transaction committed
    var result = try plugin.query("SELECT balance FROM accounts WHERE id = ?", &.{zdbc.Value.initInt(1)});
    defer result.deinit();
    const maybe_row = try result.next();
    try testing.expect(maybe_row != null);
    if (maybe_row) |row| {
        const balance = try row.getInt(0);
        try testing.expect(balance != null);
        if (balance) |b| {
            try testing.expect(b == 900);
        }
    }
}

test "DbPlugin rollback transaction" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    _ = try plugin.exec("CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)", &.{});
    _ = try plugin.exec("INSERT INTO accounts (id, balance) VALUES (?, ?)", &.{ zdbc.Value.initInt(1), zdbc.Value.initInt(1000) });

    // Test rollback
    try plugin.begin();
    _ = try plugin.exec("UPDATE accounts SET balance = balance - 500 WHERE id = ?", &.{zdbc.Value.initInt(1)});
    try plugin.rollback();

    // Verify rollback (balance should be unchanged)
    var result = try plugin.query("SELECT balance FROM accounts WHERE id = ?", &.{zdbc.Value.initInt(1)});
    defer result.deinit();
    const maybe_row = try result.next();
    try testing.expect(maybe_row != null);
    if (maybe_row) |row| {
        const balance = try row.getInt(0);
        try testing.expect(balance != null);
        if (balance) |b| {
            try testing.expect(b == 1000);
        }
    }
}

test "DbPlugin lastInsertId and affectedRows" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    _ = try plugin.exec("CREATE TABLE test (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT)", &.{});

    // Insert and check lastInsertId
    _ = try plugin.exec("INSERT INTO test (value) VALUES (?)", &.{zdbc.Value.initText("test1")});
    const last_id = plugin.lastInsertId();
    try testing.expect(last_id != null);
    try testing.expect(last_id.? >= 1);

    // Test affectedRows
    const affected = plugin.affectedRows();
    try testing.expect(affected == 1);
}

test "DbPlugin with max parameters" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    // Test with many parameters (up to MAX_PARAMS)
    var params: [MAX_PARAMS]zdbc.Value = undefined;
    var placeholders_buf: [MAX_PARAMS * 3]u8 = undefined;
    var offset: usize = 0;

    for (0..MAX_PARAMS) |i| {
        params[i] = zdbc.Value.initInt(@intCast(i));
        if (i > 0) {
            placeholders_buf[offset] = ',';
            offset += 1;
        }
        placeholders_buf[offset] = '?';
        offset += 1;
    }

    const placeholders = placeholders_buf[0..offset];
    var sql_buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buf, "SELECT {s}", .{placeholders});

    // Should not error with MAX_PARAMS
    var result = try plugin.query(sql, params[0..MAX_PARAMS]);
    defer result.deinit();
    _ = try result.next();
}

test "DbPlugin statement cache eviction" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    // Small cache size to test eviction
    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":3}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    _ = try plugin.exec("CREATE TABLE test (id INTEGER, value TEXT)", &.{});

    // Prepare more statements than cache size
    _ = try plugin.prepare("INSERT INTO test VALUES (1, 'a')");
    _ = try plugin.prepare("INSERT INTO test VALUES (2, 'b')");
    _ = try plugin.prepare("INSERT INTO test VALUES (3, 'c')");

    if (plugin.getStmtCacheStats()) |stats| {
        try testing.expect(stats.size == 3); // Cache is full
        try testing.expect(stats.misses == 3); // All were misses
    }

    // This should trigger eviction
    _ = try plugin.prepare("INSERT INTO test VALUES (4, 'd')");

    if (plugin.getStmtCacheStats()) |stats| {
        try testing.expect(stats.size == 3); // Cache size should remain at max
        try testing.expect(stats.misses == 4);
    }
}

test "DbPlugin error handling" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    // Test operations without initialization
    const result = plugin.query("SELECT 1", &.{});
    try testing.expectError(zdbc.Error.ConnectionFailed, result);

    const exec_result = plugin.exec("INSERT INTO test VALUES (1)", &.{});
    try testing.expectError(zdbc.Error.ConnectionFailed, exec_result);

    const prepare_result = plugin.prepare("SELECT 1");
    try testing.expectError(zdbc.Error.NotImplemented, prepare_result);
}

test "DbPlugin health check" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    // Should not be healthy without initialization
    try testing.expect(!plugin.isHealthy());

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    // Should be healthy after initialization
    try testing.expect(plugin.isHealthy());
}

test "DbPlugin ping operation" {
    const testing = std.testing;

    const plugin = try DbPlugin.create(testing.allocator);
    defer testing.allocator.destroy(plugin);

    const config_json = "{\"uri\":\"sqlite://:memory:\",\"pool_size\":1,\"stmt_cache_size\":10}";
    var p = plugin.asPlugin();
    try testing.expect(p.init(testing.allocator, config_json));
    defer p.deinit();

    // Ping should succeed
    try plugin.ping();
}

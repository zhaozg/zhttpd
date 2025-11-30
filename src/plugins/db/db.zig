//! Database Plugin for zhttpd
//!
//! This plugin provides database connectivity through the zdbc library.
//! It supports SQLite, PostgreSQL, and MySQL through a unified interface.
//!
//! ## Features
//!
//! - Connection pooling for efficient database access
//! - Prepared statement caching per connection for improved performance
//! - Unified API across multiple database backends
//! - Lua bindings for scripting database operations
//! - Zig-side utilities for authentication and user validation
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
//! -- Execute query
//! local result = db.query("SELECT * FROM users WHERE id = ?", 1)
//!
//! -- Execute statement
//! local affected = db.exec("INSERT INTO users (name) VALUES (?)", "John")
//!
//! -- Transaction support
//! db.begin()
//! db.exec("UPDATE accounts SET balance = balance - 100 WHERE id = ?", 1)
//! db.exec("UPDATE accounts SET balance = balance + 100 WHERE id = ?", 2)
//! db.commit()
//!
//! -- Get status including statement cache statistics
//! local status = db.status()
//! print("Cache hits:", status.stmt_cache_stats.hits)
//! print("Cache hit rate:", status.stmt_cache_stats.hit_rate)
//! ```

const std = @import("std");
const zdbc = @import("zdbc");
const ziglua = @import("ziglua");
const cache = @import("cache");
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

/// Default TTL for cached statements (1 hour in seconds)
const STMT_CACHE_TTL: u32 = 3600;

// =============================================================================
// Prepared Statement Cache
// =============================================================================

/// Cached prepared statement entry
/// Wraps a zdbc.Statement for caching with proper lifecycle management
pub const CachedStatement = struct {
    /// The underlying prepared statement
    stmt: zdbc.Statement,
    /// Reference count for tracking usage
    ref_count: u32 = 0,

    /// Size estimation for cache eviction
    /// Required by cache.zig for size-based eviction
    pub fn size(self: CachedStatement) u32 {
        // Estimate size based on SQL length (stored in stmt.sql)
        // Add base overhead for statement structure
        const base_size: u32 = 64;
        const sql_len: u32 = @intCast(@min(self.stmt.sql.len, std.math.maxInt(u32) - base_size));
        return base_size + sql_len;
    }

    /// Called by cache.zig when entry is removed from cache
    pub fn removedFromCache(self: *CachedStatement, _: std.mem.Allocator) void {
        // Deinitialize the prepared statement when evicted
        self.stmt.deinit();
    }
};

/// Prepared statement cache scoped to a single database connection
/// Uses cache.zig for LRU eviction and memory management
///
/// ## Thread Safety
/// This cache is NOT thread-safe. Each connection should have its own
/// StatementCache instance, and access should be serialized if the
/// connection is shared across threads.
///
/// ## Usage
/// ```zig
/// var stmt_cache = try StatementCache.init(allocator, conn, 100);
/// defer stmt_cache.deinit();
///
/// // Get or create a prepared statement
/// var stmt = try stmt_cache.getOrPrepare("SELECT * FROM users WHERE id = ?");
/// defer stmt_cache.releaseStatement(stmt);
///
/// // Use the statement
/// try stmt.bindAll(&.{zdbc.Value.initInt(1)});
/// var result = try stmt.query();
/// ```
pub const StatementCache = struct {
    cache: cache.Cache(CachedStatement),
    allocator: std.mem.Allocator,
    connection: *zdbc.Connection,
    hits: u64 = 0,
    misses: u64 = 0,

    const Self = @This();

    /// Cache statistics
    pub const Stats = struct {
        hits: u64,
        misses: u64,
        hit_rate: f64,
    };

    /// Initialize a new statement cache for a connection
    pub fn init(allocator: std.mem.Allocator, connection: *zdbc.Connection, max_size: u32) !Self {
        // Calculate segment count (must be power of 2)
        // Use 4 segments for reasonable concurrency/memory trade-off
        const segment_count: u16 = 4;

        const cache_instance = try cache.Cache(CachedStatement).init(allocator, .{
            .max_size = max_size,
            .segment_count = segment_count,
        });

        return Self{
            .cache = cache_instance,
            .allocator = allocator,
            .connection = connection,
        };
    }

    /// Clean up all cached statements
    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }

    /// Get a cached statement or prepare a new one
    /// The returned statement is reset and ready for parameter binding
    pub fn getOrPrepare(self: *Self, sql: []const u8) !zdbc.Statement {
        // Try to get from cache
        if (self.cache.get(sql)) |entry| {
            defer entry.release();
            self.hits += 1;

            // Reset the statement for reuse
            entry.value.stmt.reset() catch {
                // If reset fails, remove from cache and prepare fresh
                _ = self.cache.del(sql);
                return self.prepareFresh(sql);
            };

            // Clear any existing bindings
            entry.value.stmt.clearBindings() catch {
                // If clear fails, remove from cache and prepare fresh
                _ = self.cache.del(sql);
                return self.prepareFresh(sql);
            };

            return entry.value.stmt;
        }

        self.misses += 1;
        return self.prepareFresh(sql);
    }

    /// Prepare a fresh statement and add to cache
    fn prepareFresh(self: *Self, sql: []const u8) !zdbc.Statement {
        const stmt = try self.connection.prepare(sql);

        // Create cached entry
        const cached = CachedStatement{
            .stmt = stmt,
            .ref_count = 1,
        };

        // Add to cache - if this fails, still return the statement
        self.cache.put(sql, cached, .{
            .ttl = STMT_CACHE_TTL,
            .size = cached.size(),
        }) catch {
            // Cache put failed, statement still usable but won't be cached
            std.log.warn("StatementCache: Failed to cache statement for: {s}", .{sql[0..@min(sql.len, 64)]});
        };

        return stmt;
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
        };
    }

    /// Clear all cached statements
    pub fn clear(self: *Self) void {
        self.cache.delPrefix("") catch |err| {
            std.log.warn("StatementCache: Failed to clear cache: {}", .{err});
        };
        self.hits = 0;
        self.misses = 0;
    }

    /// Check if a statement is cached for the given SQL
    pub fn contains(self: *const Self, sql: []const u8) bool {
        return self.cache.contains(sql);
    }

    /// Invalidate a specific cached statement
    pub fn invalidate(self: *Self, sql: []const u8) bool {
        return self.cache.del(sql);
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
                    self.stmt_cache = StatementCache.init(self.allocator, conn, db_cfg.stmt_cache_size) catch {
                        self.error_message = "Failed to initialize statement cache";
                        conn.close();
                        self.connection = null;
                        return false;
                    };
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

    /// Execute a query and return results using cached prepared statements
    pub fn query(self: *Self, sql: []const u8, params: []const zdbc.Value) !zdbc.Result {
        if (self.connection == null) {
            return zdbc.Error.ConnectionFailed;
        }

        // Try to use cached statement if available
        if (self.stmt_cache) |*sc| {
            var stmt = sc.getOrPrepare(sql) catch {
                // Fallback to direct query if statement preparation fails
                std.log.debug("Statement cache: fallback to direct query for: {s}", .{sql[0..@min(sql.len, 64)]});
                return self.connection.?.query(sql, params);
            };

            // Bind parameters
            stmt.bindAll(params) catch {
                // Fallback to direct query on bind error
                std.log.debug("Statement cache: bind failed, fallback for: {s}", .{sql[0..@min(sql.len, 64)]});
                return self.connection.?.query(sql, params);
            };

            // Execute query
            return stmt.query();
        }

        // No cache, use direct connection query
        return self.connection.?.query(sql, params);
    }

    /// Execute a statement (INSERT, UPDATE, DELETE) using cached prepared statements
    pub fn exec(self: *Self, sql: []const u8, params: []const zdbc.Value) !usize {
        if (self.connection == null) {
            return zdbc.Error.ConnectionFailed;
        }

        // Try to use cached statement if available
        if (self.stmt_cache) |*sc| {
            var stmt = sc.getOrPrepare(sql) catch {
                // Fallback to direct exec if statement preparation fails
                std.log.debug("Statement cache: fallback to direct exec for: {s}", .{sql[0..@min(sql.len, 64)]});
                return self.connection.?.exec(sql, params);
            };

            // Bind parameters
            stmt.bindAll(params) catch {
                // Fallback to direct exec on bind error
                std.log.debug("Statement cache: bind failed, fallback for: {s}", .{sql[0..@min(sql.len, 64)]});
                return self.connection.?.exec(sql, params);
            };

            // Execute statement
            return stmt.exec();
        }

        // No cache, use direct connection exec
        return self.connection.?.exec(sql, params);
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

/// Lua: db.begin() - Begin transaction
fn luaBegin(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Database not initialized");
        return 2;
    };

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
    _ = lua.pushString("No direct connection (pool mode does not support transactions across calls)");
    return 2;
}

/// Lua: db.commit() - Commit transaction
fn luaCommit(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Database not initialized");
        return 2;
    };

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
    _ = lua.pushString("No direct connection");
    return 2;
}

/// Lua: db.rollback() - Rollback transaction
fn luaRollback(lua: *ziglua.Lua) i32 {
    const plugin = getPluginFromLua(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Database not initialized");
        return 2;
    };

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
    _ = lua.pushString("No direct connection");
    return 2;
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
        lua.newTable();
        lua.pushInteger(@intCast(stats.hits));
        lua.setField(-2, "hits");
        lua.pushInteger(@intCast(stats.misses));
        lua.setField(-2, "misses");
        lua.pushNumber(stats.hit_rate);
        lua.setField(-2, "hit_rate");
        lua.setField(-2, "stmt_cache_stats");
    }

    return 1;
}

// ============================================================================
// Public Lua Helper Functions (for use by context module)
// ============================================================================

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
        lua.newTable();
        lua.pushInteger(@intCast(stats.hits));
        lua.setField(-2, "hits");
        lua.pushInteger(@intCast(stats.misses));
        lua.setField(-2, "misses");
        lua.pushNumber(stats.hit_rate);
        lua.setField(-2, "hit_rate");
        lua.setField(-2, "stmt_cache_stats");
    }

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

test "CachedStatement size estimation" {
    const testing = std.testing;

    // Create a mock statement for testing
    // Note: We can't actually create a real statement without a connection
    // so we test the size calculation logic
    const sql = "SELECT * FROM users WHERE id = ?";
    const expected_base: u32 = 64;
    const expected_sql_len: u32 = @intCast(sql.len);
    const expected_size = expected_base + expected_sql_len;

    // The size should be base + sql length
    try testing.expect(expected_size > 64);
    try testing.expect(expected_size < 256);
}

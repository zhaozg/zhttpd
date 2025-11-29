//! Database Plugin for zhttpd
//!
//! This plugin provides database connectivity through the zdbc library.
//! It supports SQLite, PostgreSQL, and MySQL through a unified interface.
//!
//! ## Features
//!
//! - Connection pooling for efficient database access
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
};

/// Global pointer to the active database plugin
/// This is used by Lua functions to access the database plugin
/// Thread safety: The plugin itself uses thread-safe connection pooling
var global_db_plugin: ?*DbPlugin = null;

/// Set the global database plugin pointer
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
    // Note: Connection pooling is not currently supported due to zdbc API compatibility
    // Each request will use the single shared connection. For high-concurrency scenarios,
    // consider using separate database instances or implementing application-level pooling.
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

            // Store configuration (need to dupe strings for ownership)
            const uri_copy = self.allocator.dupe(u8, uri) catch {
                self.error_message = "Memory allocation failed";
                return false;
            };

            self.config = DbConfig{
                .uri = uri_copy,
                .pool_size = pool_size,
                .enable_pool = pool_size > 1,
            };

            // Initialize database connection
            if (self.config) |db_cfg| {
                // Use single connection (pooling not currently supported)
                self.connection = zdbc.open(self.allocator, db_cfg.uri) catch {
                    self.error_message = "Failed to open database connection";
                    return false;
                };
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

        // Try to ping the database
        if (self.connection) |*conn| {
            conn.ping() catch return false;
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

    /// Execute a query and return results
    pub fn query(self: *Self, sql: []const u8, params: []const zdbc.Value) !zdbc.Result {
        if (self.connection) |*conn| {
            return conn.query(sql, params);
        }
        return zdbc.Error.ConnectionFailed;
    }

    /// Execute a statement (INSERT, UPDATE, DELETE)
    pub fn exec(self: *Self, sql: []const u8, params: []const zdbc.Value) !usize {
        if (self.connection) |*conn| {
            return conn.exec(sql, params);
        }
        return zdbc.Error.ConnectionFailed;
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

    // Collect parameters
    const top = lua.getTop();
    var params_buf: [32]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
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
                    var name_buf: [256]u8 = undefined;
                    const len = @min(name.len, name_buf.len - 1);
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

    // Collect parameters
    const top = lua.getTop();
    var params_buf: [32]zdbc.Value = undefined;
    var param_count: usize = 0;

    var i: i32 = 2;
    while (i <= top and param_count < params_buf.len) : (i += 1) {
        params_buf[param_count] = luaToDbValue(lua, i);
        param_count += 1;
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
}

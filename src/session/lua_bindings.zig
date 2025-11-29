//! Lua Session Bindings
//!
//! This module provides Lua bindings for the session management system.
//! Sessions are accessed via the context object in Lua scripts:
//!
//! ```lua
//! function handle(request, response, context)
//!     local session = context:session()
//!
//!     -- Get session ID
//!     local sid = session:id()
//!
//!     -- Get/Set values
//!     session:set("user_id", 12345)
//!     local user_id = session:get("user_id")
//!
//!     -- Delete a key
//!     session:delete("temp_data")
//!
//!     -- Clear all session data
//!     session:clear()
//!
//!     -- Destroy the session
//!     session:destroy()
//!
//!     return { status = "ok" }
//! end
//! ```
//!
//! ## Thread Safety
//! Session access is thread-safe. Each request gets its own session reference.

const std = @import("std");
const ziglua = @import("ziglua");
const session_mod = @import("session.zig");
const SessionManager = session_mod.SessionManager;
const Session = session_mod.Session;
const SessionValue = @import("value.zig").SessionValue;
const SESSION_ID_HEX_LEN = session_mod.SESSION_ID_HEX_LEN;

/// Metatable name for session objects
const SESSION_MT = "zhttpd.session";

/// Maximum key size for session values
const MAX_KEY_SIZE: usize = 256;

/// Thread-local storage for current session info
threadlocal var current_session_id: ?[SESSION_ID_HEX_LEN]u8 = null;

/// Register the session metatable in Lua
pub fn registerSessionMetatable(lua: *ziglua.Lua) void {
    lua.newMetatable(SESSION_MT) catch {
        // Metatable already exists
        _ = lua.getMetatableRegistry(SESSION_MT);
    };

    // Set __index to the metatable itself for method lookup
    lua.pushValue(-1);
    lua.setField(-2, "__index");

    // Register methods
    lua.pushFunction(ziglua.wrap(sessionId));
    lua.setField(-2, "id");

    lua.pushFunction(ziglua.wrap(sessionGet));
    lua.setField(-2, "get");

    lua.pushFunction(ziglua.wrap(sessionSet));
    lua.setField(-2, "set");

    lua.pushFunction(ziglua.wrap(sessionDelete));
    lua.setField(-2, "delete");

    lua.pushFunction(ziglua.wrap(sessionClear));
    lua.setField(-2, "clear");

    lua.pushFunction(ziglua.wrap(sessionDestroy));
    lua.setField(-2, "destroy");

    lua.pushFunction(ziglua.wrap(sessionKeys));
    lua.setField(-2, "keys");

    lua.pop(1); // Pop metatable
}

/// Set the current session ID for this thread
pub fn setCurrentSession(session_id: [SESSION_ID_HEX_LEN]u8) void {
    current_session_id = session_id;
}

/// Get the current session ID for this thread
pub fn getCurrentSession() ?*const [SESSION_ID_HEX_LEN]u8 {
    if (current_session_id) |*id| {
        return id;
    }
    return null;
}

/// Clear the current session for this thread
pub fn clearCurrentSession() void {
    current_session_id = null;
}

/// Push a session object onto the Lua stack
pub fn pushSession(lua: *ziglua.Lua, session_id: [SESSION_ID_HEX_LEN]u8) void {
    // Create a table to hold the session reference
    lua.newTable();

    // Store the session ID in the table
    _ = lua.pushString(&session_id);
    lua.setField(-2, "_session_id");

    // Set the metatable
    _ = lua.getMetatableRegistry(SESSION_MT);
    lua.setMetatable(-2);
}

/// Get session ID from the Lua session object
fn getSessionIdFromLua(lua: *ziglua.Lua) ?[]const u8 {
    _ = lua.getField(1, "_session_id");
    if (lua.typeOf(-1) != .string) {
        lua.pop(1);
        return null;
    }
    const id = lua.toString(-1) catch {
        lua.pop(1);
        return null;
    };
    lua.pop(1);
    return id;
}

/// Get the session manager
fn getSessionManager() ?*SessionManager {
    return session_mod.getGlobalManager();
}

// =============================================================================
// Lua Session Methods
// =============================================================================

/// session:id() - Get the session ID
fn sessionId(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(session_id);
    return 1;
}

/// session:get(key) - Get a value from the session
fn sessionGet(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.pushNil();
        return 1;
    };

    if (lua.getTop() < 2) {
        lua.pushNil();
        return 1;
    }

    const key = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };

    const manager = getSessionManager() orelse {
        lua.pushNil();
        return 1;
    };

    if (manager.get(session_id, key)) |value| {
        pushSessionValueToLua(lua, value);
        return 1;
    }

    lua.pushNil();
    return 1;
}

/// session:set(key, value) - Set a value in the session
fn sessionSet(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    if (lua.getTop() < 3) {
        lua.pushBoolean(false);
        return 1;
    }

    const key = lua.toString(2) catch {
        lua.pushBoolean(false);
        return 1;
    };

    const manager = getSessionManager() orelse {
        lua.pushBoolean(false);
        return 1;
    };

    const value = luaToSessionValue(lua, 3, manager.allocator) catch {
        lua.pushBoolean(false);
        return 1;
    };

    manager.set(session_id, key, value) catch {
        // Value ownership was taken, it will be freed by error handling
        lua.pushBoolean(false);
        return 1;
    };

    lua.pushBoolean(true);
    return 1;
}

/// session:delete(key) - Delete a value from the session
fn sessionDelete(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    if (lua.getTop() < 2) {
        lua.pushBoolean(false);
        return 1;
    }

    const key = lua.toString(2) catch {
        lua.pushBoolean(false);
        return 1;
    };

    const manager = getSessionManager() orelse {
        lua.pushBoolean(false);
        return 1;
    };

    lua.pushBoolean(manager.deleteValue(session_id, key));
    return 1;
}

/// session:clear() - Clear all session data
fn sessionClear(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    const manager = getSessionManager() orelse {
        lua.pushBoolean(false);
        return 1;
    };

    lua.pushBoolean(manager.clearSession(session_id));
    return 1;
}

/// session:destroy() - Destroy the session entirely
fn sessionDestroy(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.pushBoolean(false);
        return 1;
    };

    const manager = getSessionManager() orelse {
        lua.pushBoolean(false);
        return 1;
    };

    lua.pushBoolean(manager.delete(session_id));
    return 1;
}

/// session:keys() - Get all keys in the session
fn sessionKeys(lua: *ziglua.Lua) i32 {
    const session_id = getSessionIdFromLua(lua) orelse {
        lua.newTable();
        return 1;
    };

    const manager = getSessionManager() orelse {
        lua.newTable();
        return 1;
    };

    lua.newTable();

    if (manager.getEntry(session_id)) |entry| {
        defer entry.release();
        var idx: i32 = 1;
        var iter = entry.value.data.iterator();
        while (iter.next()) |kv| {
            _ = lua.pushString(kv.key_ptr.*);
            lua.rawSetIndex(-2, idx);
            idx += 1;
        }
    }

    return 1;
}

// =============================================================================
// Value Conversion Helpers
// =============================================================================

/// Push a SessionValue to the Lua stack
fn pushSessionValueToLua(lua: *ziglua.Lua, value: SessionValue) void {
    switch (value) {
        .null => lua.pushNil(),
        .boolean => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(i),
        .float => |f| lua.pushNumber(f),
        .string => |s| _ = lua.pushString(s),
        .array => |a| {
            lua.newTable();
            for (a, 1..) |item, idx| {
                pushSessionValueToLua(lua, item);
                lua.rawSetIndex(-2, @intCast(idx));
            }
        },
        .object => |o| {
            lua.newTable();
            var iter = o.iterator();
            while (iter.next()) |entry| {
                pushSessionValueToLua(lua, entry.value_ptr.*);
                pushKeyToTable(lua, entry.key_ptr.*);
            }
        },
    }
}

/// Convert a Lua value to SessionValue
fn luaToSessionValue(lua: *ziglua.Lua, idx: i32, allocator: std.mem.Allocator) !SessionValue {
    return switch (lua.typeOf(idx)) {
        .nil => SessionValue.initNull(),
        .boolean => SessionValue.initBool(lua.toBoolean(idx)),
        .number => blk: {
            const num = lua.toNumber(idx) catch break :blk SessionValue.initNull();
            const int_val = lua.toInteger(idx) catch break :blk SessionValue.initFloat(num);
            if (@as(f64, @floatFromInt(int_val)) == num) {
                break :blk SessionValue.initInt(int_val);
            }
            break :blk SessionValue.initFloat(num);
        },
        .string => blk: {
            const str = lua.toString(idx) catch break :blk SessionValue.initNull();
            break :blk try SessionValue.initString(allocator, str);
        },
        .table => blk: {
            // Check if it's an array or object
            // Arrays have consecutive integer keys starting from 1
            var is_array = true;
            var max_index: i32 = 0;

            lua.pushNil();
            while (lua.next(idx)) {
                const key_type = lua.typeOf(-2);
                if (key_type != .number) {
                    is_array = false;
                    lua.pop(2);
                    break;
                }
                const key_int = lua.toInteger(-2) catch {
                    is_array = false;
                    lua.pop(2);
                    break;
                };
                if (key_int <= 0) {
                    is_array = false;
                    lua.pop(2);
                    break;
                }
                if (key_int > max_index) {
                    max_index = @intCast(key_int);
                }
                lua.pop(1); // Pop value, keep key for next iteration
            }

            if (is_array and max_index > 0) {
                // Create array
                const arr = try allocator.alloc(SessionValue, @intCast(max_index));
                errdefer allocator.free(arr);

                var i: usize = 0;
                while (i < @as(usize, @intCast(max_index))) : (i += 1) {
                    _ = lua.rawGetIndex(idx, @intCast(i + 1));
                    arr[i] = try luaToSessionValue(lua, -1, allocator);
                    lua.pop(1);
                }
                break :blk SessionValue{ .array = arr };
            } else {
                // Create object
                var obj: std.StringHashMapUnmanaged(SessionValue) = .empty;
                errdefer {
                    var iter = obj.iterator();
                    while (iter.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    obj.deinit(allocator);
                }

                lua.pushNil();
                while (lua.next(idx)) {
                    // Get key as string
                    const key_str = switch (lua.typeOf(-2)) {
                        .string => lua.toString(-2) catch {
                            lua.pop(2);
                            continue;
                        },
                        .number => blk2: {
                            // Convert number to string
                            const num = lua.toNumber(-2) catch {
                                lua.pop(2);
                                continue;
                            };
                            var buf: [32]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{num}) catch {
                                lua.pop(2);
                                continue;
                            };
                            break :blk2 s;
                        },
                        else => {
                            lua.pop(2);
                            continue;
                        },
                    };

                    const key_copy = try allocator.dupe(u8, key_str);
                    errdefer allocator.free(key_copy);

                    const val = try luaToSessionValue(lua, -1, allocator);
                    try obj.put(allocator, key_copy, val);

                    lua.pop(1); // Pop value, keep key for next iteration
                }
                break :blk SessionValue{ .object = obj };
            }
        },
        else => SessionValue.initNull(),
    };
}

/// Helper to push a key and set field in table
fn pushKeyToTable(lua: *ziglua.Lua, key: []const u8) void {
    var key_buf: [MAX_KEY_SIZE]u8 = undefined;
    const key_len = @min(key.len, key_buf.len - 1);
    @memcpy(key_buf[0..key_len], key[0..key_len]);
    key_buf[key_len] = 0;
    lua.setField(-2, key_buf[0..key_len :0]);
}

// =============================================================================
// Tests
// =============================================================================

test "session lua bindings compile" {
    // Basic compilation test
    const testing = std.testing;
    try testing.expect(true);
}

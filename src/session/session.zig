//! Session Management
//!
//! This module provides session management for zhttpd using cache.zig.
//! Sessions are stored in memory with configurable TTL and LRU eviction.
//!
//! ## Features
//! - Thread-safe session storage via cache.zig
//! - Configurable max sessions and TTL
//! - Automatic session cleanup on expiration
//! - Session ID generation using cryptographic random
//!
//! ## Thread Safety
//! All session operations are thread-safe. The SessionManager uses cache.zig
//! which provides segment-based locking for concurrent access.
//!
//! ## Usage
//! ```zig
//! var manager = try SessionManager.init(allocator, .{});
//! defer manager.deinit();
//!
//! const session_id = try manager.create();
//! try manager.set(session_id, "user_id", SessionValue.initInt(123));
//! if (manager.get(session_id, "user_id")) |value| {
//!     // Use value
//! }
//! ```

const std = @import("std");
const cache = @import("cache");
const SessionValue = @import("value.zig").SessionValue;

/// Default session TTL in seconds (30 minutes)
pub const DEFAULT_SESSION_TTL: u32 = 1800;

/// Default maximum number of sessions
pub const DEFAULT_MAX_SESSIONS: u32 = 10000;

/// Session ID length in bytes (128 bits = 16 bytes = 32 hex chars)
pub const SESSION_ID_BYTES: usize = 16;
pub const SESSION_ID_HEX_LEN: usize = SESSION_ID_BYTES * 2;

/// Session configuration
pub const SessionConfig = struct {
    /// Maximum number of sessions to keep in memory
    max_sessions: u32 = DEFAULT_MAX_SESSIONS,
    /// Default TTL for sessions in seconds
    default_ttl: u32 = DEFAULT_SESSION_TTL,
    /// Number of cache segments (power of 2, default 8)
    segment_count: u16 = 8,
    /// Cookie name for session ID
    cookie_name: []const u8 = "ZHTTPD_SESSION",
    /// Cookie secure flag (HTTPS only)
    cookie_secure: bool = true,
    /// Cookie HttpOnly flag
    cookie_http_only: bool = true,
};

/// A session contains user-defined key-value data
pub const Session = struct {
    allocator: std.mem.Allocator,
    id: [SESSION_ID_HEX_LEN]u8,
    data: std.StringHashMapUnmanaged(SessionValue),
    created_at: i64, // Unix timestamp in seconds
    last_accessed: i64, // Unix timestamp in seconds

    const Self = @This();

    /// Create a new session with a random ID
    pub fn create(allocator: std.mem.Allocator) !Self {
        var id_bytes: [SESSION_ID_BYTES]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);

        var id: [SESSION_ID_HEX_LEN]u8 = undefined;
        _ = std.fmt.bufPrint(&id, "{x:0>32}", .{std.mem.readInt(u128, &id_bytes, .big)}) catch unreachable;

        const now = std.time.timestamp();
        return Self{
            .allocator = allocator,
            .id = id,
            .data = .empty,
            .created_at = now,
            .last_accessed = now,
        };
    }

    /// Create a session with a specific ID (for loading from storage)
    pub fn createWithId(allocator: std.mem.Allocator, id: [SESSION_ID_HEX_LEN]u8) Self {
        const now = std.time.timestamp();
        return Self{
            .allocator = allocator,
            .id = id,
            .data = .empty,
            .created_at = now,
            .last_accessed = now,
        };
    }

    /// Get session ID as a slice
    pub fn getId(self: *const Self) []const u8 {
        return &self.id;
    }

    /// Size estimation for cache eviction (in bytes)
    /// Required by cache.zig for size-based eviction
    pub fn size(self: Self) u32 {
        var total: u32 = SESSION_ID_HEX_LEN + 16; // ID + timestamps
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            total +|= @intCast(@min(entry.key_ptr.*.len, std.math.maxInt(u32) - total));
            total +|= entry.value_ptr.size();
        }
        return total;
    }

    /// Called by cache.zig when the session is removed from cache
    pub fn removedFromCache(self: *Self, _: std.mem.Allocator) void {
        // Use the session's own allocator for cleanup
        self.deinit();
    }

    /// Get a value from the session
    pub fn get(self: *const Self, key: []const u8) ?SessionValue {
        return self.data.get(key);
    }

    /// Set a value in the session (takes ownership of the value)
    pub fn set(self: *Self, key: []const u8, value: SessionValue) !void {
        // Check if key already exists
        const result = self.data.getOrPut(self.allocator, key) catch |err| {
            return err;
        };

        if (result.found_existing) {
            // Free old value
            result.value_ptr.deinit(self.allocator);
        } else {
            // Need to duplicate the key
            result.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        result.value_ptr.* = value;
        self.last_accessed = std.time.timestamp();
    }

    /// Delete a value from the session
    pub fn delete(self: *Self, key: []const u8) bool {
        const entry = self.data.fetchRemove(key) orelse return false;
        self.allocator.free(entry.key);
        var val = entry.value;
        val.deinit(self.allocator);
        self.last_accessed = std.time.timestamp();
        return true;
    }

    /// Clear all session data
    pub fn clear(self: *Self) void {
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.data.clearRetainingCapacity();
        self.last_accessed = std.time.timestamp();
    }

    /// Free all memory associated with the session
    pub fn deinit(self: *Self) void {
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.data.deinit(self.allocator);
    }

    /// Get the number of keys in the session
    pub fn count(self: *const Self) usize {
        return self.data.count();
    }
};

/// Session Manager using cache.zig for thread-safe storage
pub const SessionManager = struct {
    cache: cache.Cache(Session),
    allocator: std.mem.Allocator,
    config: SessionConfig,

    const Self = @This();

    /// Initialize a new session manager
    pub fn init(allocator: std.mem.Allocator, config: SessionConfig) !Self {
        return Self{
            .cache = try cache.Cache(Session).init(allocator, .{
                .max_size = config.max_sessions,
                .segment_count = config.segment_count,
            }),
            .allocator = allocator,
            .config = config,
        };
    }

    /// Deinitialize the session manager
    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }

    /// Create a new session and return its ID
    pub fn create(self: *Self) ![SESSION_ID_HEX_LEN]u8 {
        const session = try Session.create(self.allocator);
        const id = session.id;

        try self.cache.put(&id, session, .{
            .ttl = self.config.default_ttl,
        });

        return id;
    }

    /// Get a session by ID
    /// Returns the session entry which must be released after use
    pub fn getEntry(self: *Self, session_id: []const u8) ?*cache.Entry(Session) {
        if (session_id.len != SESSION_ID_HEX_LEN) {
            return null;
        }
        return self.cache.get(session_id);
    }

    /// Get a value from a session
    pub fn get(self: *Self, session_id: []const u8, key: []const u8) ?SessionValue {
        if (self.getEntry(session_id)) |entry| {
            defer entry.release();
            return entry.value.get(key);
        }
        return null;
    }

    /// Set a value in a session
    pub fn set(self: *Self, session_id: []const u8, key: []const u8, value: SessionValue) !void {
        if (self.getEntry(session_id)) |entry| {
            defer entry.release();
            // Get mutable access to the session value
            try entry.value.set(key, value);
        } else {
            return error.SessionNotFound;
        }
    }

    /// Delete a value from a session
    pub fn deleteValue(self: *Self, session_id: []const u8, key: []const u8) bool {
        if (self.getEntry(session_id)) |entry| {
            defer entry.release();
            return entry.value.delete(key);
        }
        return false;
    }

    /// Clear all data in a session
    pub fn clearSession(self: *Self, session_id: []const u8) bool {
        if (self.getEntry(session_id)) |entry| {
            defer entry.release();
            entry.value.clear();
            return true;
        }
        return false;
    }

    /// Delete a session entirely
    pub fn delete(self: *Self, session_id: []const u8) bool {
        if (session_id.len != SESSION_ID_HEX_LEN) {
            return false;
        }
        return self.cache.del(session_id);
    }

    /// Check if a session exists
    pub fn exists(self: *Self, session_id: []const u8) bool {
        if (self.getEntry(session_id)) |entry| {
            entry.release();
            return true;
        }
        return false;
    }

    /// Get or create a session
    /// If the session exists, returns it. Otherwise creates a new one.
    pub fn getOrCreate(self: *Self, session_id: ?[]const u8) ![SESSION_ID_HEX_LEN]u8 {
        if (session_id) |sid| {
            if (sid.len == SESSION_ID_HEX_LEN) {
                if (self.exists(sid)) {
                    var id: [SESSION_ID_HEX_LEN]u8 = undefined;
                    @memcpy(&id, sid);
                    return id;
                }
            }
        }
        // Create new session
        return self.create();
    }

    /// Refresh session TTL
    pub fn touch(self: *Self, session_id: []const u8) bool {
        if (self.getEntry(session_id)) |entry| {
            defer entry.release();
            entry.value.last_accessed = std.time.timestamp();
            return true;
        }
        return false;
    }
};

/// Global session manager instance
/// Set during server initialization, before concurrent access begins
var global_session_manager: ?*SessionManager = null;

/// Set the global session manager
pub fn setGlobalManager(manager: ?*SessionManager) void {
    global_session_manager = manager;
}

/// Get the global session manager
pub fn getGlobalManager() ?*SessionManager {
    return global_session_manager;
}

// =============================================================================
// Tests
// =============================================================================

test "Session create and basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var session = try Session.create(allocator);
    defer session.deinit();

    // Check ID length
    try testing.expect(session.getId().len == SESSION_ID_HEX_LEN);

    // Set and get values
    try session.set("user_id", SessionValue.initInt(12345));
    try session.set("logged_in", SessionValue.initBool(true));

    try testing.expect(session.count() == 2);

    const user_id = session.get("user_id").?;
    try testing.expect(user_id.asInt().? == 12345);

    const logged_in = session.get("logged_in").?;
    try testing.expect(logged_in.asBool().? == true);

    // Delete value
    try testing.expect(session.delete("user_id"));
    try testing.expect(session.get("user_id") == null);
    try testing.expect(session.count() == 1);

    // Clear session
    session.clear();
    try testing.expect(session.count() == 0);
}

test "Session with string value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var session = try Session.create(allocator);
    defer session.deinit();

    const name_value = try SessionValue.initString(allocator, "John Doe");
    try session.set("name", name_value);

    const retrieved = session.get("name").?;
    try testing.expectEqualStrings("John Doe", retrieved.asString().?);
}

test "SessionManager basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try SessionManager.init(allocator, .{
        .max_sessions = 100,
        .default_ttl = 300,
    });
    defer manager.deinit();

    // Create a session
    const session_id = try manager.create();

    // Check session exists
    try testing.expect(manager.exists(&session_id));

    // Set a value
    try manager.set(&session_id, "test_key", SessionValue.initInt(42));

    // Get the value
    const value = manager.get(&session_id, "test_key").?;
    try testing.expect(value.asInt().? == 42);

    // Delete value
    try testing.expect(manager.deleteValue(&session_id, "test_key"));
    try testing.expect(manager.get(&session_id, "test_key") == null);

    // Delete session
    try testing.expect(manager.delete(&session_id));
    try testing.expect(!manager.exists(&session_id));
}

test "SessionManager getOrCreate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try SessionManager.init(allocator, .{});
    defer manager.deinit();

    // Create with no existing session
    const id1 = try manager.getOrCreate(null);
    try testing.expect(manager.exists(&id1));

    // Get existing session
    const id2 = try manager.getOrCreate(&id1);
    try testing.expectEqualSlices(u8, &id1, &id2);

    // Create with invalid session ID
    const id3 = try manager.getOrCreate("invalid");
    try testing.expect(!std.mem.eql(u8, &id1, &id3));
}

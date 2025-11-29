//! Database Manager for zhttpd
//!
//! This module manages multiple named database connections (data sources).
//! Data sources are accessed by name, with "default" being the default.
//!
//! ## Thread Safety
//! The global manager is set once during server initialization before any
//! concurrent request handling begins. After initialization, all access is
//! read-only, making it safe for concurrent access without synchronization.
//!
//! ## Usage
//!
//! ```zig
//! // Initialize the manager with data source configs
//! var manager = try DbManager.init(allocator, data_sources);
//! defer manager.deinit();
//!
//! // Get a connection by name
//! if (manager.get("default")) |plugin| {
//!     // Use plugin.query(...), plugin.exec(...), etc.
//! }
//! ```

const std = @import("std");
const zdbc = @import("zdbc");
const DbPlugin = @import("db.zig").DbPlugin;

/// Maximum URI length before truncation warning
const MAX_URI_LEN: usize = 510;

/// Configuration for a data source
pub const DataSourceConfig = struct {
    name: []const u8,
    uri: []const u8,
    pool_size: u32 = 5,
};

/// Error types for database manager operations
pub const DbManagerError = error{
    DataSourceNotFound,
    InitializationFailed,
    OutOfMemory,
    UriTooLong,
    ConfigBufferOverflow,
};

/// Database Manager that holds multiple named database plugins
pub const DbManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(*DbPlugin),

    const Self = @This();

    /// Initialize the database manager with a list of data source configs
    pub fn init(allocator: std.mem.Allocator, configs: []const DataSourceConfig) !Self {
        var manager = Self{
            .allocator = allocator,
            .plugins = std.StringHashMap(*DbPlugin).init(allocator),
        };
        errdefer manager.deinit();

        for (configs) |cfg| {
            const plugin = try DbPlugin.create(allocator);
            errdefer allocator.destroy(plugin);

            // Build config JSON for plugin initialization
            var config_buf: [1024]u8 = undefined;
            var uri_buf: [512]u8 = undefined;
            var uri_len: usize = 0;

            // Check if URI will be truncated
            if (cfg.uri.len > MAX_URI_LEN) {
                std.log.warn("Data source '{s}': URI too long ({d} chars), will be truncated to {d} chars", .{ cfg.name, cfg.uri.len, MAX_URI_LEN });
            }

            // Escape special JSON characters in the URI
            // Handles: " \ \n \r \t \b \f (JSON spec characters)
            for (cfg.uri) |c| {
                if (uri_len >= uri_buf.len - 2) {
                    std.log.warn("Data source '{s}': URI truncated during JSON escaping", .{cfg.name});
                    break;
                }
                switch (c) {
                    '"' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = '"';
                        uri_len += 1;
                    },
                    '\\' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                    },
                    '\n' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = 'n';
                        uri_len += 1;
                    },
                    '\r' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = 'r';
                        uri_len += 1;
                    },
                    '\t' => {
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = 't';
                        uri_len += 1;
                    },
                    0x08 => { // backspace
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = 'b';
                        uri_len += 1;
                    },
                    0x0C => { // form feed
                        uri_buf[uri_len] = '\\';
                        uri_len += 1;
                        uri_buf[uri_len] = 'f';
                        uri_len += 1;
                    },
                    else => {
                        uri_buf[uri_len] = c;
                        uri_len += 1;
                    },
                }
            }

            const db_config_json = std.fmt.bufPrint(&config_buf, "{{\"uri\":\"{s}\",\"pool_size\":{d}}}", .{
                uri_buf[0..uri_len],
                cfg.pool_size,
            }) catch {
                std.log.err("Data source '{s}': Config JSON buffer overflow, skipping", .{cfg.name});
                allocator.destroy(plugin);
                continue;
            };

            // Initialize the plugin
            var p = plugin.asPlugin();
            if (p.init(allocator, db_config_json)) {
                // Dupe the name for the hashmap key
                const name_key = try allocator.dupe(u8, cfg.name);
                errdefer allocator.free(name_key);
                try manager.plugins.put(name_key, plugin);
            } else {
                std.log.warn("Data source '{s}': Plugin initialization failed", .{cfg.name});
                allocator.destroy(plugin);
            }
        }

        return manager;
    }

    /// Deinitialize all managed plugins
    pub fn deinit(self: *Self) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            // Deinit and free the plugin
            var p = entry.value_ptr.*.asPlugin();
            p.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            // Free the key
            self.allocator.free(entry.key_ptr.*);
        }
        self.plugins.deinit();
    }

    /// Get a database plugin by name
    /// Returns null if the data source doesn't exist
    pub fn get(self: *Self, name: []const u8) ?*DbPlugin {
        return self.plugins.get(name);
    }

    /// Get the default database plugin
    /// Returns null if no "default" data source exists
    pub fn getDefault(self: *Self) ?*DbPlugin {
        return self.get("default");
    }

    /// Check if a data source exists
    pub fn has(self: *Self, name: []const u8) bool {
        return self.plugins.contains(name);
    }

    /// Get the number of registered data sources
    pub fn count(self: *Self) usize {
        return self.plugins.count();
    }

    /// Get all data source names
    pub fn names(self: *Self, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(allocator);
        errdefer list.deinit();

        var it = self.plugins.keyIterator();
        while (it.next()) |key| {
            try list.append(key.*);
        }
        return list.toOwnedSlice();
    }
};

// =============================================================================
// Global State (Thread Safety)
// =============================================================================

/// Global database manager instance.
///
/// ## Thread Safety
/// This global is set once during server initialization (in AppContext.init)
/// before any concurrent request handling begins, and cleared during server
/// shutdown. No synchronization is needed as the value is effectively immutable
/// during the server's operational phase.
var global_db_manager: ?*DbManager = null;

/// Set the global database manager.
/// Should only be called during server initialization or shutdown.
pub fn setGlobalManager(manager: ?*DbManager) void {
    global_db_manager = manager;
}

/// Get the global database manager
pub fn getGlobalManager() ?*DbManager {
    return global_db_manager;
}

test "DbManager basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Empty config list
    var manager = try DbManager.init(allocator, &.{});
    defer manager.deinit();

    try testing.expect(manager.count() == 0);
    try testing.expect(manager.get("default") == null);
    try testing.expect(manager.getDefault() == null);
}

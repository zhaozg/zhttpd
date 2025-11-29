//! Plugin Interface for zhttpd
//!
//! This module defines the plugin interface and plugin manager for zhttpd.
//! Plugins are optional extensions that can be loaded at runtime to add
//! additional functionality without affecting the core server.
//!
//! ## Design Principles
//!
//! 1. **Optional Loading**: Plugins are optional. If a plugin fails to initialize
//!    or is not configured, the server continues to function normally.
//!
//! 2. **VTable-based Polymorphism**: Uses Zig's VTable pattern for zero-cost
//!    abstraction and type-safe plugin interfaces.
//!
//! 3. **Lifecycle Management**: Plugins have init/deinit lifecycle hooks.
//!
//! 4. **Lua Integration**: Plugins can expose functions to Lua scripts.
//!
//! ## Plugin Types
//!
//! - Database Plugin: Provides database connectivity (zdbc)
//! - Future: Cache, Auth providers, etc.

const std = @import("std");
const ziglua = @import("ziglua");

/// Plugin state enum
pub const PluginState = enum {
    /// Plugin is not initialized
    uninitialized,
    /// Plugin is initializing
    initializing,
    /// Plugin is ready to use
    ready,
    /// Plugin initialization failed
    failed,
    /// Plugin is shutting down
    shutting_down,
    /// Plugin has been deinitialized
    deinitialized,
};

/// Plugin error types
pub const PluginError = error{
    /// Plugin initialization failed
    InitializationFailed,
    /// Plugin not found
    NotFound,
    /// Plugin already registered
    AlreadyRegistered,
    /// Plugin not ready
    NotReady,
    /// Plugin configuration error
    ConfigurationError,
    /// Plugin operation failed
    OperationFailed,
    /// Memory allocation failed
    OutOfMemory,
};

/// Plugin metadata
pub const PluginInfo = struct {
    /// Unique plugin name
    name: []const u8,
    /// Plugin version
    version: []const u8,
    /// Plugin description
    description: []const u8,
    /// Plugin author
    author: []const u8,
};

/// Plugin VTable interface
/// All plugins must implement this interface
pub const PluginVTable = struct {
    /// Get plugin information
    info: *const fn () PluginInfo,

    /// Initialize the plugin with configuration
    /// Returns true on success, false on failure
    init: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: ?[]const u8) bool,

    /// Deinitialize the plugin and release resources
    deinit: *const fn (ctx: *anyopaque) void,

    /// Check if the plugin is healthy
    health_check: ?*const fn (ctx: *anyopaque) bool,

    /// Register Lua functions for this plugin
    register_lua: ?*const fn (ctx: *anyopaque, lua: *ziglua.Lua) bool,

    /// Handle a request (optional, for request-processing plugins)
    on_request: ?*const fn (ctx: *anyopaque, request_ctx: *anyopaque) bool,
};

/// Plugin wrapper that holds the plugin context and vtable
pub const Plugin = struct {
    /// Plugin implementation context
    ctx: *anyopaque,
    /// Plugin vtable
    vtable: *const PluginVTable,
    /// Current plugin state
    state: PluginState,
    /// Error message if initialization failed
    error_message: ?[]const u8,

    /// Get plugin info
    pub fn info(self: *const Plugin) PluginInfo {
        return self.vtable.info();
    }

    /// Initialize the plugin
    pub fn init(self: *Plugin, allocator: std.mem.Allocator, config: ?[]const u8) bool {
        self.state = .initializing;
        const success = self.vtable.init(self.ctx, allocator, config);
        self.state = if (success) .ready else .failed;
        return success;
    }

    /// Deinitialize the plugin
    pub fn deinit(self: *Plugin) void {
        if (self.state == .ready or self.state == .failed) {
            self.state = .shutting_down;
            self.vtable.deinit(self.ctx);
            self.state = .deinitialized;
        }
    }

    /// Check if the plugin is ready
    pub fn isReady(self: *const Plugin) bool {
        return self.state == .ready;
    }

    /// Perform health check
    pub fn healthCheck(self: *const Plugin) bool {
        if (self.state != .ready) return false;
        if (self.vtable.health_check) |check_fn| {
            return check_fn(self.ctx);
        }
        return true; // Default to healthy if no health check function
    }

    /// Register Lua functions
    pub fn registerLua(self: *Plugin, lua: *ziglua.Lua) bool {
        if (self.state != .ready) return false;
        if (self.vtable.register_lua) |register_fn| {
            return register_fn(self.ctx, lua);
        }
        return true; // Default to success if no Lua registration
    }
};

/// Plugin manager for registering and managing plugins
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(Plugin),

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return PluginManager{
            .allocator = allocator,
            .plugins = std.StringHashMap(Plugin).init(allocator),
        };
    }

    pub fn deinit(self: *PluginManager) void {
        // Deinitialize all plugins
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            var plugin = entry.value_ptr;
            plugin.deinit();
        }
        self.plugins.deinit();
    }

    /// Register a plugin
    pub fn register(self: *PluginManager, name: []const u8, plugin: Plugin) PluginError!void {
        if (self.plugins.contains(name)) {
            return PluginError.AlreadyRegistered;
        }
        self.plugins.put(name, plugin) catch return PluginError.OutOfMemory;
    }

    /// Get a plugin by name
    pub fn get(self: *PluginManager, name: []const u8) ?*Plugin {
        return self.plugins.getPtr(name);
    }

    /// Check if a plugin exists and is ready
    pub fn isReady(self: *PluginManager, name: []const u8) bool {
        if (self.plugins.getPtr(name)) |plugin| {
            return plugin.isReady();
        }
        return false;
    }

    /// Initialize all registered plugins
    pub fn initAll(self: *PluginManager, config_map: std.StringHashMap([]const u8)) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            var plugin = entry.value_ptr;
            const config = config_map.get(entry.key_ptr.*);
            _ = plugin.init(self.allocator, config);
        }
    }

    /// Register Lua functions for all ready plugins
    pub fn registerAllLua(self: *PluginManager, lua: *ziglua.Lua) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            var plugin = entry.value_ptr;
            if (plugin.isReady()) {
                _ = plugin.registerLua(lua);
            }
        }
    }

    /// Get health status of all plugins
    pub fn healthStatus(self: *PluginManager, allocator: std.mem.Allocator) !std.StringHashMap(bool) {
        var status = std.StringHashMap(bool).init(allocator);
        errdefer status.deinit();

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const plugin = entry.value_ptr;
            try status.put(entry.key_ptr.*, plugin.healthCheck());
        }
        return status;
    }
};

test "plugin manager basic operations" {
    const testing = std.testing;
    var manager = PluginManager.init(testing.allocator);
    defer manager.deinit();

    // Test that manager starts empty
    try testing.expect(manager.get("test") == null);
    try testing.expect(!manager.isReady("test"));
}

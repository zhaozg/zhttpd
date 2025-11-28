//! Handler Interface Module
//!
//! This module defines the unified Handler interface that all HTTP handlers
//! must implement. Handlers are registered by name and can be mapped to
//! URL patterns via the configuration file.
//!
//! ## Architecture
//!
//! The handler system follows a plugin-like architecture:
//! 1. Each handler type implements the Handler interface
//! 2. Handlers are registered in a central registry by name
//! 3. URL patterns are mapped to handler names in configuration
//! 4. At startup, routes are configured based on the handler mappings
//!
//! ## Handler Registration
//!
//! Handlers are registered with unique names that can be referenced in config:
//! - `Handler.StaticFileHandler` - Serves static files
//! - `Handler.LuaHandler` - Executes Lua scripts
//! - `Handler.GraphQLHandler` - Handles GraphQL requests
//! - `Handler.WebSocketHandler` - Handles WebSocket connections
//! - `Handler.HealthCheckHandler` - Returns health status
//! - `Handler.MetricsHandler` - Returns Prometheus metrics
//! - `Handler.SSEHandler` - Handles Server-Sent Events
//!
//! ## Configuration Example (YAML)
//!
//! ```yaml
//! handlers:
//!   /ws: Handler.WebSocketHandler
//!   /api/*: Handler.LuaHandler
//!   /health: Handler.HealthCheckHandler
//!   /metrics: Handler.MetricsHandler
//!   /graphql: Handler.GraphQLHandler
//!   /*: Handler.StaticFileHandler
//! ```

const std = @import("std");
const httpz = @import("httpz");

/// Handler function type that matches httpz's route handler signature.
/// All handlers must conform to this type.
pub const HandlerFn = fn (ctx: *anyopaque, req: *httpz.Request, res: *httpz.Response) anyerror!void;

/// Handler registration entry
pub const HandlerEntry = struct {
    name: []const u8,
    handler: HandlerFn,
};

/// Handler mapping from URL pattern to handler name
pub const HandlerMapping = struct {
    pattern: []const u8,
    handler_name: []const u8,
};

/// Handler configuration parsed from YAML
pub const HandlersConfig = struct {
    mappings: []HandlerMapping,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HandlersConfig) void {
        for (self.mappings) |mapping| {
            self.allocator.free(mapping.pattern);
            self.allocator.free(mapping.handler_name);
        }
        self.allocator.free(self.mappings);
    }
};

/// Built-in handler names
pub const HandlerNames = struct {
    pub const StaticFileHandler = "Handler.StaticFileHandler";
    pub const LuaHandler = "Handler.LuaHandler";
    pub const GraphQLHandler = "Handler.GraphQLHandler";
    pub const WebSocketHandler = "Handler.WebSocketHandler";
    pub const HealthCheckHandler = "Handler.HealthCheckHandler";
    pub const MetricsHandler = "Handler.MetricsHandler";
    pub const SSEHandler = "Handler.SSEHandler";
};

/// Handler registry for looking up handlers by name
pub const HandlerRegistry = struct {
    entries: std.StringHashMap(HandlerFn),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HandlerRegistry {
        return .{
            .entries = std.StringHashMap(HandlerFn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HandlerRegistry) void {
        self.entries.deinit();
    }

    pub fn register(self: *HandlerRegistry, name: []const u8, handler: HandlerFn) !void {
        try self.entries.put(name, handler);
    }

    pub fn get(self: *HandlerRegistry, name: []const u8) ?HandlerFn {
        return self.entries.get(name);
    }
};

// Tests
test "handler registry basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = HandlerRegistry.init(allocator);
    defer registry.deinit();

    // Test registration and lookup
    const test_handler: HandlerFn = struct {
        fn handle(_: *anyopaque, _: *httpz.Request, _: *httpz.Response) !void {}
    }.handle;

    try registry.register("test.handler", test_handler);

    const found = registry.get("test.handler");
    try testing.expect(found != null);

    const not_found = registry.get("nonexistent");
    try testing.expect(not_found == null);
}

test "handler names constants" {
    const testing = std.testing;

    try testing.expectEqualStrings("Handler.StaticFileHandler", HandlerNames.StaticFileHandler);
    try testing.expectEqualStrings("Handler.LuaHandler", HandlerNames.LuaHandler);
    try testing.expectEqualStrings("Handler.HealthCheckHandler", HandlerNames.HealthCheckHandler);
}

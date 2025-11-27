const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;

/// WebSocket module for zhttpd
/// Provides WebSocket support with Lua integration for message handling.
///
/// Architecture:
/// - Each WebSocket connection is handled by a WebSocketHandler instance
/// - Messages are delegated to Lua scripts for processing via websocket.lua
/// - Supports text and binary messages
/// - Integrates with GraphQL subscriptions
///
/// Lua Interface:
/// The websocket.lua script receives messages in the format:
/// {
///   type = "message" | "connect" | "disconnect",
///   connection_id = <number>,
///   path = "/ws",
///   data = <message data>
/// }
///
/// The script should return a response table:
/// {
///   action = "send" | "broadcast" | "close" | "none",
///   data = <response data>,
///   target = <connection_id> (optional, for targeted send)
/// }

/// Allocator for WebSocket operations - passed from context
var global_allocator: ?std.mem.Allocator = null;

/// Set the allocator for WebSocket operations
pub fn setAllocator(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}
/// WebSocket message types for Lua interface
pub const MessageType = enum {
    text,
    binary,
    ping,
    pong,
    close,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .text => "text",
            .binary => "binary",
            .ping => "ping",
            .pong => "pong",
            .close => "close",
        };
    }
};

/// Thread-safe connection ID generator
var connection_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn generateConnectionId() u64 {
    return connection_id_counter.fetchAdd(1, .monotonic);
}

/// Context passed during WebSocket upgrade
pub const WebSocketContext = struct {
    /// Request path that initiated the upgrade
    path: []const u8,
    /// Connection ID for tracking
    connection_id: u64,
    /// Pointer to the LuaHandler for script execution
    lua_handler: ?*LuaHandler = null,

    pub fn init(path: []const u8, lua_handler: ?*LuaHandler) WebSocketContext {
        return .{
            .path = path,
            .connection_id = generateConnectionId(),
            .lua_handler = lua_handler,
        };
    }
};

/// WebSocket handler for httpz integration
/// This is the type that httpz uses for each WebSocket connection
pub const WebSocketHandler = struct {
    conn: *websocket.Conn,
    connection_id: u64,
    path: []const u8,
    lua_handler: ?*LuaHandler,

    /// Initialize a new WebSocket handler
    pub fn init(conn: *websocket.Conn, ctx: *const WebSocketContext) !WebSocketHandler {
        return .{
            .conn = conn,
            .connection_id = ctx.connection_id,
            .path = ctx.path,
            .lua_handler = ctx.lua_handler,
        };
    }

    /// Called after successful WebSocket handshake
    pub fn afterInit(self: *WebSocketHandler) !void {
        // Send welcome message
        var buf: [256]u8 = undefined;
        const welcome = std.fmt.bufPrint(&buf, "{{\"type\":\"connected\",\"connection_id\":{d},\"path\":\"{s}\"}}", .{ self.connection_id, self.path }) catch {
            return self.conn.write("{\"type\":\"connected\"}");
        };
        try self.conn.write(welcome);

        // Notify Lua of the connection
        if (self.lua_handler) |_| {
            _ = self.executeLuaHandler("connect", "") catch |err| {
                std.debug.print("WebSocket Lua connect error: {}\n", .{err});
            };
        }
    }

    /// Handle incoming client message
    pub fn clientMessage(self: *WebSocketHandler, data: []const u8) !void {
        if (self.lua_handler) |_| {
            // Execute Lua websocket handler
            const response = self.executeLuaHandler("message", data) catch |err| {
                std.debug.print("WebSocket Lua message error: {}\n", .{err});
                // On error, echo back with error info
                var buf: [512]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"Handler error\"}}", .{}) catch {
                    return self.conn.write("{\"type\":\"error\"}");
                };
                return self.conn.write(err_msg);
            };
            // Send the Lua response back to client
            return self.conn.write(response);
        } else {
            // No Lua handler, echo the message
            return self.conn.write(data);
        }
    }

    /// Execute Lua websocket handler script
    fn executeLuaHandler(self: *WebSocketHandler, event_type: []const u8, data: []const u8) ![]const u8 {
        const handler = self.lua_handler orelse return error.NoLuaHandler;

        // Build request JSON for Lua
        // Use a thread-local buffer for building the request
        var request_buf: [8192]u8 = undefined;
        const escaped_data = escapeJsonString(data);
        const request_json = std.fmt.bufPrint(&request_buf, "{{\"type\":\"{s}\",\"connection_id\":{d},\"path\":\"{s}\",\"data\":\"{s}\"}}", .{
            event_type,
            self.connection_id,
            self.path,
            escaped_data,
        }) catch {
            return error.BufferOverflow;
        };

        // Create an arena for this execution
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        // Execute the websocket Lua script
        return handler.executeScript(arena.allocator(), "websocket", "WEBSOCKET", self.path, request_json);
    }

    /// Close the connection
    pub fn close(self: *WebSocketHandler) void {
        // Notify Lua of disconnect
        if (self.lua_handler) |_| {
            _ = self.executeLuaHandler("disconnect", "") catch {};
        }
        self.conn.close(.{}) catch {};
    }
};

/// Escape a string for JSON embedding
fn escapeJsonString(input: []const u8) []const u8 {
    // For simplicity, we'll just return the input if it's safe
    // A full implementation would escape special characters
    for (input) |c| {
        if (c == '"' or c == '\\' or c < 32) {
            // Has characters that need escaping - for now just return empty
            // TODO: Implement proper escaping
            return "";
        }
    }
    return input;
}

/// Check if a request is a WebSocket upgrade request
pub fn isWebSocketRequest(req: *httpz.Request) bool {
    const upgrade = req.header("upgrade") orelse return false;
    return std.ascii.eqlIgnoreCase(upgrade, "websocket");
}

// Tests
test "websocket context init" {
    const testing = std.testing;

    const ctx1 = WebSocketContext.init("/ws", null);
    const ctx2 = WebSocketContext.init("/ws", null);

    try testing.expect(ctx1.connection_id != ctx2.connection_id);
    try testing.expectEqualStrings("/ws", ctx1.path);
}

test "message type to string" {
    const testing = std.testing;

    try testing.expectEqualStrings("text", MessageType.text.toString());
    try testing.expectEqualStrings("binary", MessageType.binary.toString());
    try testing.expectEqualStrings("close", MessageType.close.toString());
}

test "escape json string" {
    const testing = std.testing;

    // Test simple string
    const simple = "hello world";
    try testing.expectEqualStrings("hello world", escapeJsonString(simple));

    // Test string with special chars returns empty for safety
    const special = "hello\"world";
    try testing.expectEqualStrings("", escapeJsonString(special));
}

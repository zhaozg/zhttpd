const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
const ziglua = @import("ziglua");
const json = @import("../lua/json.zig");

/// WebSocket module for zhttpd
/// Provides WebSocket support with Lua integration for message handling.
///
/// Architecture:
/// - Each WebSocket connection has its own dedicated Lua VM
/// - Lua VM is created in init() and destroyed in close()
/// - Messages are handled by calling Lua functions for each event
/// - Supports text and binary messages
/// - Integrates with GraphQL subscriptions
///
/// Lua Interface:
/// The websocket.lua script should export:
/// - afterInit(conn): Called after connection established
/// - handle_message(conn, data): Called when message received
/// - on_close(conn): Called before connection closes
///
/// The conn object provides:
/// - conn:send(data): Send data to client
/// - conn:close(): Close the connection
/// - conn.id: Connection ID
/// - conn.path: WebSocket path
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

/// Response constants for websocket stub implementation
const RESPONSE_CONNECTED = "{\"type\":\"connected\"}";
const RESPONSE_OK = "{\"type\":\"ok\"}";

/// Per-connection Lua VM for WebSocket
const WebSocketLuaVM = struct {
    lua: *ziglua.Lua,
    allocator: std.mem.Allocator,
    script_loaded: bool = false,

    fn init(allocator: std.mem.Allocator) !WebSocketLuaVM {
        var lua = try ziglua.Lua.init(allocator);
        lua.openLibs();

        // Register JSON module for Lua
        json.registerJsonModule(lua, &getLuaAllocator);

        return WebSocketLuaVM{
            .lua = lua,
            .allocator = allocator,
            .script_loaded = false,
        };
    }

    fn deinit(self: *WebSocketLuaVM) void {
        self.lua.deinit();
    }

    /// Load and cache the websocket.lua script
    fn loadScript(self: *WebSocketLuaVM, lua_handler: *LuaHandler) !void {
        if (self.script_loaded) return;

        const script_content = lua_handler.loadScript("websocket") catch |err| {
            return err;
        };
        defer lua_handler.allocator.free(script_content);

        // Load the script
        const load_result = if (@import("build_options").lua_lang == .luajit)
            self.lua.loadBuffer(script_content, "@websocket.lua")
        else
            self.lua.loadBuffer(script_content, "@websocket.lua", .text);

        load_result catch {
            self.lua.pop(1);
            return error.ScriptLoadFailed;
        };

        // Execute the script to load the module
        self.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
            self.lua.pop(1);
            return error.ScriptExecutionFailed;
        };

        // Verify it's a table
        if (self.lua.typeOf(-1) != .table) {
            self.lua.pop(1);
            return error.ModuleNotTable;
        }

        // Store the module in global _WEBSOCKET_MODULE
        self.lua.setGlobal("_WEBSOCKET_MODULE");

        self.script_loaded = true;
    }

    /// Call a Lua function from the websocket module
    fn callLuaFunction(self: *WebSocketLuaVM, func_name: []const u8, args: anytype) ![]const u8 {
        // Get the module from registry (stored as global for now)
        _ = self.lua.getGlobal("websocket_module") catch {
            return error.ModuleNotFound;
        };

        if (self.lua.typeOf(-1) != .table) {
            self.lua.pop(1);
            return error.ModuleNotTable;
        }

        // Get the function from the module
        const func_z = try self.allocator.dupeZ(u8, func_name);
        defer self.allocator.free(func_z);
        _ = self.lua.getField(-1, func_z);

        if (self.lua.typeOf(-1) != .function) {
            self.lua.pop(2);
            return error.FunctionNotFound;
        }

        // Remove module table, keep function
        self.lua.remove(-2);

        // Push arguments
        inline for (args) |arg| {
            switch (@TypeOf(arg)) {
                []const u8 => _ = self.lua.pushString(arg),
                u64 => self.lua.pushNumber(@floatFromInt(arg)),
                else => @compileError("Unsupported argument type"),
            }
        }

        // Call the function
        self.lua.protectedCall(.{ .args = args.len, .results = 1 }) catch {
            self.lua.pop(1);
            return error.FunctionCallFailed;
        };

        // Convert result to JSON
        const result = json.luaValueToJson(self.allocator, self.lua, -1) catch {
            self.lua.pop(1);
            return error.JsonConversionFailed;
        };
        self.lua.pop(1);

        return result;
    }
};

/// Get allocator for Lua JSON module
fn getLuaAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// WebSocket handler for httpz integration
/// This is the type that httpz uses for each WebSocket connection
pub const WebSocketHandler = struct {
    conn: *websocket.Conn,
    connection_id: u64,
    path: []const u8,
    lua_handler: ?*LuaHandler,
    lua_vm: ?WebSocketLuaVM = null,
    allocator: std.mem.Allocator,

    /// Initialize a new WebSocket handler
    pub fn init(conn: *websocket.Conn, ctx: *const WebSocketContext) !WebSocketHandler {
        const allocator = std.heap.page_allocator;

        // Create per-connection Lua VM if Lua handler is available
        var lua_vm: ?WebSocketLuaVM = null;
        if (ctx.lua_handler) |handler| {
            if (WebSocketLuaVM.init(allocator)) |vm| {
                var mutable_vm = vm;
                // Try to load the script
                mutable_vm.loadScript(handler) catch |err| {
                    std.debug.print("Failed to load websocket.lua: {}\n", .{err});
                    mutable_vm.deinit();
                };
                if (mutable_vm.script_loaded) {
                    lua_vm = mutable_vm;
                } else {
                    mutable_vm.deinit();
                }
            } else |err| {
                std.debug.print("Failed to create Lua VM for websocket: {}\n", .{err});
            }
        }

        return .{
            .conn = conn,
            .connection_id = ctx.connection_id,
            .path = ctx.path,
            .lua_handler = ctx.lua_handler,
            .lua_vm = lua_vm,
            .allocator = allocator,
        };
    }

    /// Called after successful WebSocket handshake
    pub fn afterInit(self: *WebSocketHandler) !void {
        // Send welcome message
        var buf: [256]u8 = undefined;
        const welcome = std.fmt.bufPrint(&buf, "{{\"type\":\"connected\",\"connection_id\":{d},\"path\":\"{s}\"}}", .{ self.connection_id, self.path }) catch {
            return self.conn.write(RESPONSE_CONNECTED);
        };
        try self.conn.write(welcome);

        // Call Lua afterInit if available
        if (self.lua_vm) |*vm| {
            _ = self.executeLuaHandler(vm, "handle_connect", "") catch |err| {
                std.debug.print("WebSocket Lua afterInit error: {}\n", .{err});
            };
        }
    }

    /// Handle incoming client message
    pub fn clientMessage(self: *WebSocketHandler, data: []const u8) !void {
        if (self.lua_vm) |*vm| {
            // Execute Lua message handler
            const response = self.executeLuaHandler(vm, "handle_message", data) catch |err| {
                std.debug.print("WebSocket Lua message error: {}\n", .{err});
                // On error, echo back with error info
                var buf: [512]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"Handler error: {s}\"}}", .{@errorName(err)}) catch {
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

    /// Execute Lua websocket handler script with per-connection Lua VM
    fn executeLuaHandler(self: *WebSocketHandler, vm: *WebSocketLuaVM, event_type: []const u8, data: []const u8) ![]const u8 {
        // Build request table for Lua
        var request_buf: [8192]u8 = undefined;
        var escape_buf: [4096]u8 = undefined;

        const escaped_data = escapeJsonStringBuf(data, &escape_buf) orelse "";

        const request_json = std.fmt.bufPrint(&request_buf, "{{\"type\":\"{s}\",\"connection_id\":{d},\"path\":\"{s}\",\"data\":\"{s}\"}}", .{
            event_type,
            self.connection_id,
            self.path,
            escaped_data,
        }) catch {
            return error.BufferOverflow;
        };

        // Push the request as a table to Lua
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request_json, .{}) catch {
            return error.JsonParseFailed;
        };
        defer parsed.deinit();

        vm.lua.newTable();

        // Set fields from parsed JSON
        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const key_z = self.allocator.dupeZ(u8, entry.key_ptr.*) catch continue;
                defer self.allocator.free(key_z);

                switch (entry.value_ptr.*) {
                    .string => |s| _ = vm.lua.pushString(s),
                    .number_string => |n| vm.lua.pushNumber(std.fmt.parseFloat(f64, n) catch 0),
                    .integer => |i| vm.lua.pushNumber(@floatFromInt(i)),
                    else => continue,
                }
                vm.lua.setField(-2, key_z);
            }
        }

        // Store as global 'request'
        vm.lua.setGlobal("request");

        // Get the websocket module
        _ = vm.lua.getGlobal("_WEBSOCKET_MODULE") catch {
            // Module not loaded, try to load it
            if (self.lua_handler) |handler| {
                vm.loadScript(handler) catch {
                    return error.ScriptLoadFailed;
                };
            } else {
                return error.NoLuaHandler;
            }
        };

        if (vm.lua.typeOf(-1) != .table) {
            vm.lua.pop(1);
            return error.ModuleNotTable;
        }

        // Get the handler function
        const func_name = if (std.mem.eql(u8, event_type, "connect"))
            "handle_connect"
        else if (std.mem.eql(u8, event_type, "disconnect"))
            "handle_disconnect"
        else
            "handle_message";

        const func_z = self.allocator.dupeZ(u8, func_name) catch {
            vm.lua.pop(1);
            return error.AllocFailed;
        };
        defer self.allocator.free(func_z);

        _ = vm.lua.getField(-1, func_z);
        if (vm.lua.typeOf(-1) != .function) {
            vm.lua.pop(2);
            return error.FunctionNotFound;
        }

        // Remove module table, keep function
        vm.lua.remove(-2);

        // Push request table as argument
        _ = vm.lua.getGlobal("request") catch {
            vm.lua.pop(1);
            return error.RequestNotFound;
        };

        // Call the function
        vm.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            vm.lua.pop(1);
            return error.FunctionCallFailed;
        };

        // Convert result to JSON
        const result = json.luaValueToJson(self.allocator, vm.lua, -1) catch {
            vm.lua.pop(1);
            return error.JsonConversionFailed;
        };
        vm.lua.pop(1);

        return result;
    }

    /// Close the connection
    pub fn close(self: *WebSocketHandler) void {
        // Notify Lua of disconnect
        if (self.lua_vm) |*vm| {
            _ = self.executeLuaHandler(vm, "disconnect", "") catch {};
            vm.deinit();
        }
        self.conn.close(.{}) catch {};
    }
};

/// Escape a string for JSON embedding into a provided buffer
/// Returns the escaped string or null if buffer is too small
fn escapeJsonStringBuf(input: []const u8, buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    for (input) |c| {
        const escaped: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 32) null else null, // Control chars handled below
        };
        if (escaped) |esc| {
            if (pos + esc.len > buf.len) return null;
            @memcpy(buf[pos..][0..esc.len], esc);
            pos += esc.len;
        } else if (c < 32) {
            // Escape control characters as \u00XX
            if (pos + 6 > buf.len) return null;
            _ = std.fmt.bufPrint(buf[pos..][0..6], "\\u{x:0>4}", .{c}) catch return null;
            pos += 6;
        } else {
            if (pos >= buf.len) return null;
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
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

test "escape json string buf" {
    const testing = std.testing;

    // Test simple string
    var buf: [256]u8 = undefined;
    const simple = "hello world";
    const result1 = escapeJsonStringBuf(simple, &buf);
    try testing.expect(result1 != null);
    try testing.expectEqualStrings("hello world", result1.?);

    // Test string with special chars - should be properly escaped
    const special = "hello\"world";
    const result2 = escapeJsonStringBuf(special, &buf);
    try testing.expect(result2 != null);
    try testing.expectEqualStrings("hello\\\"world", result2.?);

    // Test newlines
    const newline = "line1\nline2";
    const result3 = escapeJsonStringBuf(newline, &buf);
    try testing.expect(result3 != null);
    try testing.expectEqualStrings("line1\\nline2", result3.?);
}

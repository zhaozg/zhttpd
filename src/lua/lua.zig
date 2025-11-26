const std = @import("std");
const ziglua = @import("ziglua");

// Lua integration module
// This module provides integration with Lua for dynamic content handling
// Based on ziglua: https://github.com/natecraddock/ziglua

pub const LuaHandler = struct {
    allocator: std.mem.Allocator,
    scripts_dir: []const u8,
    lua: *ziglua.Lua,

    pub fn init(allocator: std.mem.Allocator, scripts_dir: []const u8) !LuaHandler {
        // Create Lua state
        var lua = try ziglua.Lua.init(allocator);
        errdefer lua.deinit();

        // Open standard libraries
        lua.openLibs();

        return LuaHandler{
            .allocator = allocator,
            .scripts_dir = scripts_dir,
            .lua = lua,
        };
    }

    pub fn deinit(self: *LuaHandler) void {
        self.lua.deinit();
    }

    pub fn executeScript(self: *LuaHandler, script_name: []const u8, request_data: []const u8) ![]const u8 {
        _ = request_data; // TODO: Pass request data to Lua

        // Load script file
        const script_content = try self.loadScript(script_name);
        defer self.allocator.free(script_content);

        // Convert to null-terminated string for Lua
        const script_z = try self.allocator.dupeZ(u8, script_content);
        defer self.allocator.free(script_z);

        // Execute Lua script
        self.lua.doString(script_z) catch |err| {
            std.debug.print("Error executing Lua script: {}\n", .{err});
            return try self.allocator.dupe(u8, "{\"status\":\"error\",\"message\":\"Lua execution failed\"}");
        };

        // For now, return a success message
        // TODO: Capture Lua return value and convert to JSON
        return try self.allocator.dupe(u8, "{\"status\":\"ok\",\"message\":\"Lua script executed\"}");
    }

    pub fn loadScript(self: *LuaHandler, script_name: []const u8) ![]const u8 {
        // Security: Prevent path traversal attacks
        if (std.mem.indexOf(u8, script_name, "..") != null or
            std.mem.indexOf(u8, script_name, "/") != null or
            std.mem.indexOf(u8, script_name, "\\") != null)
        {
            return error.InvalidScriptName;
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.lua", .{ self.scripts_dir, script_name });

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 1024 * 1024);
    }
};

test "lua handler init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try LuaHandler.init(allocator, "./examples/lua");
    defer handler.deinit();

    try testing.expect(handler.scripts_dir.len > 0);
}

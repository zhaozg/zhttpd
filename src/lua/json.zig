//! JSON encoding/decoding module for Lua integration
//!
//! This module integrates lua-cjson (https://github.com/mpx/lua-cjson) for
//! high-performance JSON encoding and decoding. lua-cjson is written in C
//! and provides ~60x faster performance compared to the previous Zig std.json
//! implementation.
//!
//! The module exposes:
//! - json.encode(value) - Convert Lua value to JSON string
//! - json.decode(json_string) - Parse JSON string to Lua value
//! - json.null - Sentinel value representing JSON null

const std = @import("std");
const ziglua = @import("ziglua");

// Import the C luaopen_cjson function from lua-cjson library
// This is linked from vendor/lua-cjson compiled with zig build
extern fn luaopen_cjson(L: ?*ziglua.LuaState) c_int;

/// Maximum safe integer value for JSON compatibility (JavaScript Number.MAX_SAFE_INTEGER)
/// Values beyond this range may lose precision when parsed by JavaScript
pub const JSON_MAX_SAFE_INTEGER: f64 = 9007199254740992;
pub const JSON_MIN_SAFE_INTEGER: f64 = -9007199254740992;

/// Buffer pre-allocation constants for JSON encoding (used by legacy code)
/// These are conservative upper-bound estimates to reduce memory reallocations
const STRING_ESCAPE_OVERHEAD_RATIO = 4;
const ARRAY_ELEMENT_AVG_SIZE = 20;
const OBJECT_DEFAULT_SIZE = 128;

/// Escape a string for JSON output, appending the escaped content to the buffer
/// Handles quotes, backslashes, and control characters according to RFC 8259
/// Note: This function is kept for backward compatibility with other parts
/// of the codebase that may use it directly.
pub fn appendJsonEscapedString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"), // backspace
            0x0c => try buf.appendSlice(allocator, "\\f"), // form feed
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                // Escape other control characters as \uXXXX
                try buf.appendSlice(allocator, "\\u00");
                try buf.append(allocator, "0123456789abcdef"[c >> 4]);
                try buf.append(allocator, "0123456789abcdef"[c & 0x0f]);
            },
            else => try buf.append(allocator, c),
        }
    }
}

/// Register the json module using lua-cjson
/// This provides high-performance JSON encoding/decoding (~60x faster than Zig std.json)
/// The allocator parameter is kept for API compatibility but is not used by lua-cjson.
pub fn registerJsonModule(lua: *ziglua.Lua, getAllocator: *const fn () std.mem.Allocator) !void {
    _ = getAllocator;

    _ = lua.getGlobal("package");
    _ = lua.getField(-1, "preload");
    lua.pushFunction(luaopen_cjson);
    _ = lua.setField(-2, "json");
    lua.pop(2); // pop package and preload
}

/// Thread-local storage for allocator getter function (for legacy code compatibility)
threadlocal var allocator_getter: ?*const fn () std.mem.Allocator = null;

// ============================================================================
// Helper functions for internal request/response JSON handling
// These are used by lua.zig and context.zig for parsing HTTP request bodies
// and serializing Lua response values. They use Zig std.json for consistency
// with the existing codebase.
// ============================================================================

/// Push a JSON value onto the Lua stack
pub fn pushJsonValue(lua: *ziglua.Lua, value: std.json.Value) !void {
    switch (value) {
        .null => lua.pushNil(),
        .bool => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(@intCast(i)),
        .float => |f| lua.pushNumber(f),
        .number_string => |ns| {
            const num = std.fmt.parseFloat(f64, ns) catch {
                _ = lua.pushString(ns);
                return;
            };
            lua.pushNumber(num);
        },
        .string => |s| _ = lua.pushString(s),
        .array => |arr| {
            lua.newTable();
            for (arr.items, 0..) |item, i| {
                try pushJsonValue(lua, item);
                lua.setIndexRaw(-2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            lua.newTable();
            var it = obj.iterator();
            while (it.next()) |entry| {
                _ = lua.pushString(entry.key_ptr.*);
                try pushJsonValue(lua, entry.value_ptr.*);
                lua.setTable(-3);
            }
        },
    }
}

/// Convert a Lua value to JSON string
/// Uses a pre-allocated buffer to avoid ArrayListUnmanaged resize issues
/// with arena allocators that don't support remap/resize operations.
pub fn luaValueToJson(allocator: std.mem.Allocator, lua: *ziglua.Lua, index: i32) ![]const u8 {
    // Use page_allocator for internal ArrayList operations to avoid remap/resize
    // issues with arena allocators (which don't support remap of non-arena memory).
    // The final result is copied to the provided allocator.
    const pa = std.heap.page_allocator;
    const lua_type = lua.typeOf(index);

    switch (lua_type) {
        .nil => return try allocator.dupe(u8, "null"),
        .boolean => {
            const b = lua.toBoolean(index);
            return try allocator.dupe(u8, if (b) "true" else "false");
        },
        .number => {
            const n = lua.toNumber(index) catch 0.0;
            const is_whole_number = @floor(n) == n and n >= JSON_MIN_SAFE_INTEGER and n <= JSON_MAX_SAFE_INTEGER;
            if (is_whole_number) {
                const i: i64 = @intFromFloat(n);
                return try std.fmt.allocPrint(allocator, "{d}", .{i});
            } else {
                return try std.fmt.allocPrint(allocator, "{d}", .{n});
            }
        },
        .string => {
            const s = lua.toString(index) catch "";
            // Pre-allocate buffer with estimated size (string length + quotes + escape overhead)
            // Use saturating arithmetic to prevent overflow for very large strings
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(pa);
            const escape_overhead = s.len / STRING_ESCAPE_OVERHEAD_RATIO;
            const estimated_size = s.len +| 2 +| escape_overhead;
            try buf.ensureTotalCapacity(pa, estimated_size);
            try buf.append(pa, '"');
            try appendJsonEscapedString(&buf, pa, s);
            try buf.append(pa, '"');
            const owned = try buf.toOwnedSlice(pa);
            defer pa.free(owned);
            return try allocator.dupe(u8, owned);
        },
        .table => {
            // Determine if table is an array (sequence) or object.
            // We use rawLen() which returns the length of the sequence part.
            // A table is treated as an array if rawLen > 0.
            // Note: Mixed tables (with both integer and string keys) will serialize
            // only the sequence part when treated as array. For pure objects, use
            // tables with only string keys.
            const len = lua.lenRaw(index);
            const is_array = len > 0;

            // Pre-allocate buffer with estimated size based on table length
            // Use saturating arithmetic to prevent overflow for very large arrays
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(pa);
            const estimated_size: usize = if (is_array) @as(usize, @intCast(len)) *| ARRAY_ELEMENT_AVG_SIZE +| 2 else OBJECT_DEFAULT_SIZE;
            try buf.ensureTotalCapacity(pa, estimated_size);

            if (is_array) {
                try buf.append(pa, '[');
                var i: i32 = 1;
                while (i <= len) : (i += 1) {
                    if (i > 1) try buf.append(pa, ',');
                    _ = lua.getIndexRaw(index, i);
                    const value_json = try luaValueToJson(allocator, lua, -1);
                    try buf.appendSlice(pa, value_json);
                    lua.pop(1);
                }
                try buf.append(pa, ']');
            } else {
                try buf.append(pa, '{');
                lua.pushNil();
                // After pushNil, the table index needs adjustment:
                // - For negative indices: the table moved (e.g., -1 becomes -2)
                // - For positive indices: they remain the same
                const table_index = if (index < 0) index - 1 else index;
                var first = true;
                while (lua.next(table_index)) {
                    if (!first) try buf.append(pa, ',');
                    first = false;

                    // JSON object keys must be strings
                    const key_type = lua.typeOf(-2);
                    const key = if (key_type == .string)
                        lua.toString(-2) catch ""
                    else if (key_type == .number)
                        // Convert numeric keys to string (common in Lua)
                        blk: {
                            const n = lua.toNumber(-2) catch 0.0;
                            break :blk std.fmt.allocPrint(allocator, "{d}", .{n}) catch "";
                        } else
                        // Skip non-serializable keys
                        "";

                    if (key.len > 0) {
                        try buf.append(pa, '"');
                        try appendJsonEscapedString(&buf, pa, key);
                        try buf.appendSlice(pa, "\":");

                        const value_json = try luaValueToJson(allocator, lua, -1);
                        try buf.appendSlice(pa, value_json);
                    } else {
                        // If key was skipped, remove the trailing comma
                        if (!first and buf.items.len > 0 and buf.items[buf.items.len - 1] == ',') {
                            _ = buf.pop();
                        }
                        first = true; // Reset to avoid adding comma before next valid key
                    }

                    lua.pop(1);
                }
                try buf.append(pa, '}');
            }

            const owned = try buf.toOwnedSlice(pa);
            defer pa.free(owned);
            return try allocator.dupe(u8, owned);
        },
        .light_userdata => {
            // json.null is represented as light userdata with null pointer
            return try allocator.dupe(u8, "null");
        },
        else => {
            return try allocator.dupe(u8, "null");
        },
    }
}

// Tests

test "appendJsonEscapedString handles special characters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test escaping quotes
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "hello \"world\"");
        try testing.expectEqualStrings("hello \\\"world\\\"", buf.items);
    }

    // Test escaping backslashes
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "path\\to\\file");
        try testing.expectEqualStrings("path\\\\to\\\\file", buf.items);
    }

    // Test escaping newlines
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "line1\nline2");
        try testing.expectEqualStrings("line1\\nline2", buf.items);
    }

    // Test escaping tabs
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "col1\tcol2");
        try testing.expectEqualStrings("col1\\tcol2", buf.items);
    }

    // Test escaping carriage return
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\rafter");
        try testing.expectEqualStrings("before\\rafter", buf.items);
    }

    // Test escaping backspace
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x08after");
        try testing.expectEqualStrings("before\\bafter", buf.items);
    }

    // Test escaping form feed
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x0cafter");
        try testing.expectEqualStrings("before\\fafter", buf.items);
    }

    // Test escaping null character
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x00after");
        try testing.expectEqualStrings("before\\u0000after", buf.items);
    }

    // Test escaping other control characters (e.g., 0x01)
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x01after");
        try testing.expectEqualStrings("before\\u0001after", buf.items);
    }
}

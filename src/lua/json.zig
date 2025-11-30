//! JSON encoding/decoding module for Lua integration
//!
//! This module provides JSON serialization and deserialization for Lua values,
//! including the cjson module that is exposed to Lua scripts.
//!
//! The module handles:
//! - Converting Lua values to JSON strings (encode)
//! - Parsing JSON strings to Lua values (decode)
//! - RFC 8259 compliant string escaping
//! - Safe integer handling for JavaScript compatibility

const std = @import("std");
const ziglua = @import("ziglua");

/// Maximum safe integer value for JSON compatibility (JavaScript Number.MAX_SAFE_INTEGER)
/// Values beyond this range may lose precision when parsed by JavaScript
pub const JSON_MAX_SAFE_INTEGER: f64 = 9007199254740992;
pub const JSON_MIN_SAFE_INTEGER: f64 = -9007199254740992;

/// Buffer pre-allocation constants for JSON encoding
/// These are conservative upper-bound estimates to reduce memory reallocations
/// In practice, most strings have far fewer escapable characters
const STRING_ESCAPE_OVERHEAD_RATIO = 4; // Worst case: 1 in 4 chars may need escaping
const ARRAY_ELEMENT_AVG_SIZE = 20; // Average JSON element size (e.g., "123" or "\"text\"")
const OBJECT_DEFAULT_SIZE = 128; // Default buffer for objects with unknown size

/// Escape a string for JSON output, appending the escaped content to the buffer
/// Handles quotes, backslashes, and control characters according to RFC 8259
pub fn appendJsonEscapedString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
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

/// Register the built-in cjson module
/// Provides cjson-compatible API: cjson.encode() and cjson.decode()
/// Note: This function is called once per thread when the Lua VM is initialized.
/// The allocator_getter is threadlocal to avoid data races between worker threads.
pub fn registerCjsonModule(lua: *ziglua.Lua, getAllocator: *const fn () std.mem.Allocator) void {
    // Store the allocator getter in thread-local storage
    allocator_getter = getAllocator;

    // Create the cjson table
    lua.newTable();

    // Add encode function
    lua.pushFunction(ziglua.wrap(cjsonEncode));
    lua.setField(-2, "encode");

    // Add decode function
    lua.pushFunction(ziglua.wrap(cjsonDecode));
    lua.setField(-2, "decode");

    // Add null value (cjson.null) - use a unique sentinel value
    // We use a small integer as a sentinel since light userdata requires non-null
    lua.pushNil();
    lua.setField(-2, "null");

    // Set as global 'cjson'
    lua.setGlobal("cjson");
}

/// Thread-local storage for allocator getter function to avoid data races
threadlocal var allocator_getter: ?*const fn () std.mem.Allocator = null;

/// cjson.encode(value) - Convert Lua value to JSON string
fn cjsonEncode(lua: *ziglua.Lua) i32 {
    // Check if we have an argument
    if (lua.getTop() < 1) {
        _ = lua.pushString("cjson.encode: requires 1 argument");
        lua.raiseError();
    }

    // Get thread-local allocator
    const allocator = if (allocator_getter) |getter| getter() else std.heap.page_allocator;

    // Use a temporary arena for JSON encoding
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_str = luaValueToJson(arena.allocator(), lua, 1) catch {
        _ = lua.pushString("cjson.encode: failed to encode value");
        lua.raiseError();
    };

    _ = lua.pushString(json_str);
    return 1;
}

/// cjson.decode(json_string) - Parse JSON string to Lua value
fn cjsonDecode(lua: *ziglua.Lua) i32 {
    // Check if we have an argument
    if (lua.getTop() < 1) {
        _ = lua.pushString("cjson.decode: requires 1 argument");
        lua.raiseError();
    }

    // Check if argument is a string
    if (lua.typeOf(1) != .string) {
        _ = lua.pushString("cjson.decode: argument must be a string");
        lua.raiseError();
    }

    const json_str = lua.toString(1) catch {
        _ = lua.pushString("cjson.decode: failed to get string");
        lua.raiseError();
    };

    // Get thread-local allocator
    const allocator = if (allocator_getter) |getter| getter() else std.heap.page_allocator;

    // Use a temporary arena for JSON parsing
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json_str, .{}) catch {
        _ = lua.pushString("cjson.decode: invalid JSON");
        lua.raiseError();
    };

    pushJsonValue(lua, parsed.value) catch {
        _ = lua.pushString("cjson.decode: failed to convert JSON to Lua");
        lua.raiseError();
    };

    return 1;
}

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
                lua.rawSetIndex(-2, @intCast(i + 1));
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
pub fn luaValueToJson(allocator: std.mem.Allocator, lua: *ziglua.Lua, index: i32) ![]const u8 {
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
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(allocator);
            const escape_overhead = s.len / STRING_ESCAPE_OVERHEAD_RATIO;
            const estimated_size = s.len +| 2 +| escape_overhead;
            try buf.ensureTotalCapacity(allocator, estimated_size);
            try buf.append(allocator, '"');
            try appendJsonEscapedString(&buf, allocator, s);
            try buf.append(allocator, '"');
            return try buf.toOwnedSlice(allocator);
        },
        .table => {
            // Determine if table is an array (sequence) or object.
            // We use rawLen() which returns the length of the sequence part.
            // A table is treated as an array if rawLen > 0, matching cjson behavior.
            // Note: Mixed tables (with both integer and string keys) will serialize
            // only the sequence part when treated as array. For pure objects, use
            // tables with only string keys.
            const len = lua.rawLen(index);
            const is_array = len > 0;

            // Pre-allocate buffer with estimated size based on table length
            // Use saturating arithmetic to prevent overflow for very large arrays
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(allocator);
            const estimated_size: usize = if (is_array) @as(usize, @intCast(len)) *| ARRAY_ELEMENT_AVG_SIZE +| 2 else OBJECT_DEFAULT_SIZE;
            try buf.ensureTotalCapacity(allocator, estimated_size);

            if (is_array) {
                try buf.append(allocator, '[');
                var i: i32 = 1;
                while (i <= len) : (i += 1) {
                    if (i > 1) try buf.append(allocator, ',');
                    _ = lua.rawGetIndex(index, i);
                    const value_json = try luaValueToJson(allocator, lua, -1);
                    try buf.appendSlice(allocator, value_json);
                    lua.pop(1);
                }
                try buf.append(allocator, ']');
            } else {
                try buf.append(allocator, '{');
                lua.pushNil();
                // After pushNil, the table index needs adjustment:
                // - For negative indices: the table moved (e.g., -1 becomes -2)
                // - For positive indices: they remain the same
                const table_index = if (index < 0) index - 1 else index;
                var first = true;
                while (lua.next(table_index)) {
                    if (!first) try buf.append(allocator, ',');
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
                        try buf.append(allocator, '"');
                        try appendJsonEscapedString(&buf, allocator, key);
                        try buf.appendSlice(allocator, "\":");

                        const value_json = try luaValueToJson(allocator, lua, -1);
                        try buf.appendSlice(allocator, value_json);
                    } else {
                        // If key was skipped, remove the trailing comma
                        if (!first and buf.items.len > 0 and buf.items[buf.items.len - 1] == ',') {
                            _ = buf.pop();
                        }
                        first = true; // Reset to avoid adding comma before next valid key
                    }

                    lua.pop(1);
                }
                try buf.append(allocator, '}');
            }

            return try buf.toOwnedSlice(allocator);
        },
        .light_userdata => {
            // cjson.null is represented as light userdata with null pointer
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
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "hello \"world\"");
        try testing.expectEqualStrings("hello \\\"world\\\"", buf.items);
    }

    // Test escaping backslashes
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "path\\to\\file");
        try testing.expectEqualStrings("path\\\\to\\\\file", buf.items);
    }

    // Test escaping newlines
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "line1\nline2");
        try testing.expectEqualStrings("line1\\nline2", buf.items);
    }

    // Test escaping tabs
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "col1\tcol2");
        try testing.expectEqualStrings("col1\\tcol2", buf.items);
    }

    // Test escaping carriage return
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\rafter");
        try testing.expectEqualStrings("before\\rafter", buf.items);
    }

    // Test escaping backspace
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x08after");
        try testing.expectEqualStrings("before\\bafter", buf.items);
    }

    // Test escaping form feed
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x0cafter");
        try testing.expectEqualStrings("before\\fafter", buf.items);
    }

    // Test escaping null character
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x00after");
        try testing.expectEqualStrings("before\\u0000after", buf.items);
    }

    // Test escaping other control characters (e.g., 0x01)
    {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try appendJsonEscapedString(&buf, allocator, "before\x01after");
        try testing.expectEqualStrings("before\\u0001after", buf.items);
    }
}

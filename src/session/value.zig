//! Session Value Type
//!
//! This module defines the SessionValue type for storing session data.
//! SessionValue supports multiple types similar to YAML Value, but optimized
//! for runtime session usage with proper cache integration.
//!
//! ## Supported Types
//! - null: No value
//! - boolean: true/false
//! - integer: 64-bit signed integer
//! - float: 64-bit floating point
//! - string: UTF-8 string
//! - array: Array of SessionValue
//! - object: Key-value map of SessionValue
//!
//! ## Thread Safety
//! SessionValue instances are NOT thread-safe by themselves.
//! Thread safety is provided by the SessionManager which uses cache.zig.

const std = @import("std");

/// Session value type supporting multiple data types.
/// Designed for interoperability between Zig and Lua.
pub const SessionValue = union(enum) {
    null: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []SessionValue,
    object: std.StringHashMapUnmanaged(SessionValue),

    const Self = @This();

    /// Create a null value
    pub fn initNull() Self {
        return .{ .null = {} };
    }

    /// Create a boolean value
    pub fn initBool(value: bool) Self {
        return .{ .boolean = value };
    }

    /// Create an integer value
    pub fn initInt(value: i64) Self {
        return .{ .integer = value };
    }

    /// Create a float value
    pub fn initFloat(value: f64) Self {
        return .{ .float = value };
    }

    /// Create a string value (caller owns the string, this duplicates it)
    pub fn initString(allocator: std.mem.Allocator, value: []const u8) !Self {
        return .{ .string = try allocator.dupe(u8, value) };
    }

    /// Create a string value from an owned slice (takes ownership)
    pub fn initStringOwned(value: []const u8) Self {
        return .{ .string = value };
    }

    /// Create an empty array with optional pre-allocation
    /// Note: Returns an empty slice. Elements must be added using append patterns.
    /// The caller is responsible for tracking the actual length.
    pub fn initEmptyArray() Self {
        return .{ .array = &.{} };
    }

    /// Create an empty object
    pub fn initObject() Self {
        return .{ .object = .empty };
    }

    /// Size estimation for cache eviction (in bytes).
    /// Required by cache.zig for size-based eviction.
    pub fn size(self: Self) u32 {
        return switch (self) {
            .null, .boolean => 1,
            .integer, .float => 8,
            .string => |s| @intCast(@min(s.len + 1, std.math.maxInt(u32))),
            .array => |a| blk: {
                var total: u32 = 4; // Array overhead
                for (a) |item| {
                    total +|= item.size();
                }
                break :blk total;
            },
            .object => |o| blk: {
                var total: u32 = 16; // HashMap overhead
                var iter = o.iterator();
                while (iter.next()) |entry| {
                    // Use saturating addition to prevent overflow
                    const key_len: u32 = @intCast(@min(entry.key_ptr.*.len, std.math.maxInt(u32)));
                    total +|= key_len;
                    total +|= entry.value_ptr.size();
                }
                break :blk total;
            },
        };
    }

    /// Deep clone this value
    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        return switch (self) {
            .null => .{ .null = {} },
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |a| blk: {
                const new_arr = try allocator.alloc(SessionValue, a.len);
                errdefer allocator.free(new_arr);
                for (a, 0..) |item, i| {
                    new_arr[i] = try item.clone(allocator);
                }
                break :blk .{ .array = new_arr };
            },
            .object => |o| blk: {
                var new_obj: std.StringHashMapUnmanaged(SessionValue) = .empty;
                errdefer {
                    var iter = new_obj.iterator();
                    while (iter.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    new_obj.deinit(allocator);
                }
                var iter = o.iterator();
                while (iter.next()) |entry| {
                    const new_key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(new_key);
                    const new_val = try entry.value_ptr.clone(allocator);
                    try new_obj.put(allocator, new_key, new_val);
                }
                break :blk .{ .object = new_obj };
            },
        };
    }

    /// Free all memory associated with this value
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .null, .boolean, .integer, .float => {},
            .string => |s| {
                allocator.free(s);
            },
            .array => |a| {
                for (a) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(a);
            },
            .object => |*o| {
                var iter = o.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                o.deinit(allocator);
            },
        }
        self.* = .{ .null = {} };
    }

    /// Check if value is null
    pub fn isNull(self: Self) bool {
        return self == .null;
    }

    /// Get boolean value, returns null if not a boolean
    pub fn asBool(self: Self) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Get integer value, returns null if not an integer
    pub fn asInt(self: Self) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Get float value, returns null if not a float
    pub fn asFloat(self: Self) ?f64 {
        return switch (self) {
            .float => |f| f,
            else => null,
        };
    }

    /// Get string value, returns null if not a string
    pub fn asString(self: Self) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    /// Get array value, returns null if not an array
    pub fn asArray(self: Self) ?[]SessionValue {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    /// Get object value, returns null if not an object
    pub fn asObject(self: *Self) ?*std.StringHashMapUnmanaged(SessionValue) {
        return switch (self.*) {
            .object => |*o| o,
            else => null,
        };
    }

    /// Format for debug output
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .null => try writer.writeAll("null"),
            .boolean => |b| try writer.print("{}", .{b}),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .array => |a| {
                try writer.writeAll("[");
                for (a, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
            .object => |o| {
                try writer.writeAll("{");
                var first = true;
                var iter = o.iterator();
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                    try entry.value_ptr.format("", .{}, writer);
                }
                try writer.writeAll("}");
            },
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SessionValue basic types" {
    const testing = std.testing;

    const null_val = SessionValue.initNull();
    try testing.expect(null_val.isNull());
    try testing.expect(null_val.size() == 1);

    const bool_val = SessionValue.initBool(true);
    try testing.expect(bool_val.asBool().? == true);
    try testing.expect(bool_val.size() == 1);

    const int_val = SessionValue.initInt(12345);
    try testing.expect(int_val.asInt().? == 12345);
    try testing.expect(int_val.size() == 8);

    const float_val = SessionValue.initFloat(3.14159);
    try testing.expect(float_val.asFloat().? == 3.14159);
    try testing.expect(float_val.size() == 8);
}

test "SessionValue string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var str_val = try SessionValue.initString(allocator, "hello world");
    defer str_val.deinit(allocator);

    try testing.expectEqualStrings("hello world", str_val.asString().?);
    try testing.expect(str_val.size() == 12); // 11 chars + 1
}

test "SessionValue object" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var obj_val = SessionValue.initObject();
    defer obj_val.deinit(allocator);

    // Add some values to the object
    var obj = obj_val.asObject().?;
    const key1 = try allocator.dupe(u8, "name");
    errdefer allocator.free(key1);
    try obj.put(allocator, key1, try SessionValue.initString(allocator, "John"));

    const key2 = try allocator.dupe(u8, "age");
    errdefer allocator.free(key2);
    try obj.put(allocator, key2, SessionValue.initInt(30));

    try testing.expect(obj.count() == 2);

    // Check values
    if (obj.get("name")) |name_val| {
        try testing.expectEqualStrings("John", name_val.asString().?);
    } else {
        return error.TestFailed;
    }

    if (obj.get("age")) |age_val| {
        try testing.expect(age_val.asInt().? == 30);
    } else {
        return error.TestFailed;
    }
}

test "SessionValue clone" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var original = try SessionValue.initString(allocator, "original");
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expectEqualStrings("original", cloned.asString().?);
    // Verify they are independent copies
    try testing.expect(original.asString().?.ptr != cloned.asString().?.ptr);
}

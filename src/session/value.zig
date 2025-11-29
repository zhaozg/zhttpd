//! Session Value Type
//!
//! This module defines the SessionValue type for storing session data.
//! SessionValue supports primitive types for simple session storage.
//!
//! ## Supported Types
//! - null: No value
//! - boolean: true/false
//! - integer: 64-bit signed integer
//! - float: 64-bit floating point
//! - string: Binary-safe string (supports arbitrary bytes including null)
//!
//! ## Binary Data Support
//! Lua strings are binary-safe and can contain any bytes including null bytes.
//! This is fully supported on the Zig side - strings are stored and retrieved
//! using length-based operations, not null-terminated.
//!
//! ## Complex Objects
//! For complex objects (arrays, nested objects), use JSON strings.
//! This simplifies implementation while maintaining flexibility.
//!
//! ## Thread Safety
//! SessionValue instances are NOT thread-safe by themselves.
//! Thread safety is provided by the SessionManager which uses cache.zig.

const std = @import("std");

/// Session value type supporting primitive data types.
/// For complex objects, store them as JSON strings.
/// Designed for interoperability between Zig and Lua.
pub const SessionValue = union(enum) {
    null: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,

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

    /// Size estimation for cache eviction (in bytes).
    /// Required by cache.zig for size-based eviction.
    pub fn size(self: Self) u32 {
        return switch (self) {
            .null, .boolean => 1,
            .integer, .float => 8,
            .string => |s| @intCast(@min(s.len + 1, std.math.maxInt(u32))),
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
        };
    }

    /// Free all memory associated with this value
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .null, .boolean, .integer, .float => {},
            .string => |s| {
                allocator.free(s);
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

test "SessionValue JSON string for complex objects" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Complex objects should be stored as JSON strings
    const json_str =
        \\{"name":"John","age":30,"items":[1,2,3]}
    ;

    var json_val = try SessionValue.initString(allocator, json_str);
    defer json_val.deinit(allocator);

    try testing.expectEqualStrings(json_str, json_val.asString().?);
}

test "SessionValue binary string support" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Binary data with null bytes (common in Lua)
    const binary_data = "hello\x00world\x00\x01\x02\x03";

    var bin_val = try SessionValue.initString(allocator, binary_data);
    defer bin_val.deinit(allocator);

    const retrieved = bin_val.asString().?;
    try testing.expect(retrieved.len == binary_data.len);
    try testing.expectEqualSlices(u8, binary_data, retrieved);

    // Verify size calculation includes full binary length
    try testing.expect(bin_val.size() == binary_data.len + 1);
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

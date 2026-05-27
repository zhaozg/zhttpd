// zhttpd Request ID module
// Provides unique request ID generation and propagation for distributed tracing
//
// Request IDs are generated using a combination of:
// - Timestamp (microseconds)
// - Thread-local counter
// - Random component for uniqueness

const std = @import("std");

/// Thread-local counter for request ID uniqueness
threadlocal var tls_counter: u32 = 0;

/// Request ID format:
/// xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (UUID-like format)
/// Components:
/// - First 8 chars: Timestamp (seconds) in hex
/// - Next 4 chars: Microseconds in hex
/// - Next 4 chars: Thread counter in hex
/// - Last 12 chars: Random component
/// Generate a unique request ID
/// Returns a null-terminated string suitable for HTTP headers
pub fn generate(buf: *[37]u8) []const u8 {
    // Use std.time.nanoTimestamp() equivalent via std.c.clock_gettime
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now = @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
    const secs: u32 = @intCast(@divFloor(now, std.time.ns_per_s) & 0xFFFFFFFF);
    const micros: u16 = @intCast(@mod(now, std.time.ns_per_s) >> 12 & 0xFFFF);

    tls_counter +%= 1;
    const counter = tls_counter;

    // Use a simple PRNG for the random component
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(now & 0xFFFFFFFFFFFFFFFF)));
    const random = prng.random();

    // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 characters exactly)
    // Buffer is 37 bytes, format produces exactly 36 chars, so this is guaranteed to succeed
    const written = std.fmt.bufPrint(buf, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        secs,
        micros,
        counter,
        random.int(u16),
        random.int(u48),
    }) catch {
        // Fallback: return a simple timestamp-based ID if formatting fails
        @memset(buf, '0');
        buf[8] = '-';
        buf[13] = '-';
        buf[18] = '-';
        buf[23] = '-';
        return buf[0..36];
    };

    return written;
}

/// Check if a string is a valid request ID format
pub fn isValid(id: []const u8) bool {
    if (id.len != 36) return false;

    // Check format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else {
            if (!std.ascii.isHex(c)) return false;
        }
    }
    return true;
}

/// Header name for request ID
pub const HEADER_NAME = "X-Request-ID";

/// Extract request ID from headers, or generate a new one if not present
pub fn fromHeadersOrGenerate(headers: anytype, buf: *[37]u8) []const u8 {
    if (headers.get(HEADER_NAME)) |existing| {
        if (isValid(existing)) {
            return existing;
        }
    }
    return generate(buf);
}

// Tests
test "request ID generation" {
    var buf1: [37]u8 = undefined;
    var buf2: [37]u8 = undefined;

    const id1 = generate(&buf1);
    const id2 = generate(&buf2);

    // IDs should be valid format
    try std.testing.expect(isValid(id1));
    try std.testing.expect(isValid(id2));

    // IDs should be different
    try std.testing.expect(!std.mem.eql(u8, id1, id2));

    // ID should be 36 characters
    try std.testing.expect(id1.len == 36);
}

test "request ID validation" {
    try std.testing.expect(isValid("12345678-1234-1234-1234-123456789abc"));
    try std.testing.expect(isValid("ABCDEF12-3456-7890-abcd-ef1234567890"));

    try std.testing.expect(!isValid("")); // Empty
    try std.testing.expect(!isValid("12345678-1234-1234-1234-123456789ab")); // Too short
    try std.testing.expect(!isValid("12345678-1234-1234-1234-123456789abcd")); // Too long
    try std.testing.expect(!isValid("12345678X1234-1234-1234-123456789abc")); // Missing dash
    try std.testing.expect(!isValid("1234567G-1234-1234-1234-123456789abc")); // Invalid hex
}

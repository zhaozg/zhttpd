const std = @import("std");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn toJsonLevel(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

pub const LogFormat = enum {
    text,
    json,
};

/// Format a log message into a buffer
/// Returns the formatted message slice
pub fn formatMessage(
    buf: []u8,
    level: LogLevel,
    format: LogFormat,
    message: []const u8,
    request_id: ?[]const u8,
) ![]const u8 {
    const timestamp = formatTimestamp();

    return switch (format) {
        .text => if (request_id) |rid|
            try std.fmt.bufPrint(buf, "[{s}] [{s}] [{s}] {s}\n", .{
                &timestamp,
                level.toString(),
                rid,
                message,
            })
        else
            try std.fmt.bufPrint(buf, "[{s}] [{s}] {s}\n", .{
                &timestamp,
                level.toString(),
                message,
            }),
        .json => blk: {
            var escaped_buf: [4096]u8 = undefined;
            const escaped_msg = escapeJsonString(message, &escaped_buf);

            if (request_id) |rid| {
                break :blk try std.fmt.bufPrint(buf, "{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"request_id\":\"{s}\",\"message\":\"{s}\"}}\n", .{
                    &timestamp,
                    level.toJsonLevel(),
                    rid,
                    escaped_msg,
                });
            } else {
                break :blk try std.fmt.bufPrint(buf, "{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"message\":\"{s}\"}}\n", .{
                    &timestamp,
                    level.toJsonLevel(),
                    escaped_msg,
                });
            }
        },
    };
}

/// Format current timestamp as human-readable string with microsecond precision
/// Format: YYYY-MM-DD HH:MM:SS.microseconds
pub fn formatTimestamp() [26]u8 {
    const now = std.time.microTimestamp();
    const epoch_seconds: u64 = @intCast(@divFloor(now, std.time.us_per_s));
    const microseconds: u64 = @intCast(@mod(@mod(now, std.time.us_per_s) + std.time.us_per_s, std.time.us_per_s));

    const seconds_per_day = 86400;
    const days_since_epoch = epoch_seconds / seconds_per_day;
    const seconds_today = epoch_seconds % seconds_per_day;

    var days_remaining = days_since_epoch;
    var year: u32 = 1970;

    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (days_remaining < days_in_year) break;
        days_remaining -= days_in_year;
        year += 1;
    }

    const is_leap = isLeapYear(year);
    const days_in_months = if (is_leap)
        [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u32 = 1;
    for (days_in_months) |days_in_month| {
        if (days_remaining < days_in_month) break;
        days_remaining -= days_in_month;
        month += 1;
    }
    const day = days_remaining + 1;

    const hours = seconds_today / 3600;
    const minutes = (seconds_today % 3600) / 60;
    const seconds = seconds_today % 60;

    var buf: [26]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
        microseconds,
    }) catch unreachable;
    return buf;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Escape a string for JSON
fn escapeJsonString(input: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (input) |c| {
        const escaped: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escaped) |esc| {
            if (pos + esc.len > buf.len) break;
            @memcpy(buf[pos..][0..esc.len], esc);
            pos += esc.len;
        } else if (c < 32) {
            if (pos + 6 > buf.len) break;
            _ = std.fmt.bufPrint(buf[pos..][0..6], "\\u{x:0>4}", .{c}) catch break;
            pos += 6;
        } else {
            if (pos >= buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
}

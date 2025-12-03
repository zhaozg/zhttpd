//! Refactored Logger Module
//!
//! This module provides a high-performance, extensible logger with the following features:
//! - Async logging with ordered message delivery
//! - Zero-allocation hot path using stack buffers
//! - Pluggable backends (file, console, custom)
//! - Thread-safe operation
//! - Support for text and JSON formats
//! - std.log compatibility
//! - Configurable console output

const std = @import("std");

// Re-export new logger implementation
pub const logger_v2 = @import("logger_v2.zig");
pub const Backend = logger_v2.Backend;
pub const FileBackend = logger_v2.FileBackend;
pub const ConsoleBackend = logger_v2.ConsoleBackend;
pub const MultiBackend = logger_v2.MultiBackend;
pub const LogLevel = logger_v2.LogLevel;
pub const LogFormat = logger_v2.LogFormat;
pub const LoggerConfig = logger_v2.LoggerConfig;

// Re-export for backward compatibility
pub const Logger = LegacyLogger;

/// Legacy Logger wrapper providing backward compatibility
/// This maintains the old API while using the new implementation under the hood
pub const LegacyLogger = struct {
    inner: logger_v2.Logger,
    allocator: std.mem.Allocator,
    level: LogLevel,
    format: LogFormat,
    // Note: file_backend is managed by inner logger's backend.deinit()
    // We don't store the pointer here to avoid double-free

    /// Initialize logger with file path (legacy API)
    pub fn init(allocator: std.mem.Allocator, level: LogLevel, log_file_path: ?[]const u8) !LegacyLogger {
        return initWithFormat(allocator, level, log_file_path, .text);
    }

    /// Initialize logger with format specification (legacy API)
    pub fn initWithFormat(allocator: std.mem.Allocator, level: LogLevel, log_file_path: ?[]const u8, format: LogFormat) !LegacyLogger {
        var backend: ?Backend = null;

        if (log_file_path) |path| {
            const file_backend = try FileBackend.init(allocator, path);
            backend = file_backend.backend();
        }

        const config = LoggerConfig{
            .level = level,
            .format = format,
            .enable_console = true, // Legacy behavior: always enable console
            .enable_async = false, // Legacy behavior: sync by default
        };

        const inner = try logger_v2.Logger.init(allocator, config, backend);

        return LegacyLogger{
            .inner = inner,
            .allocator = allocator,
            .level = level,
            .format = format,
        };
    }

    pub fn deinit(self: *LegacyLogger) void {
        self.inner.deinit();
    }

    pub fn log(self: *LegacyLogger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        self.inner.log(level, fmt, args);
    }

    pub fn logWithRequestId(self: *LegacyLogger, level: LogLevel, request_id: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        self.inner.logWithRequestId(level, request_id, fmt, args);
    }

    pub fn debug(self: *LegacyLogger, comptime fmt: []const u8, args: anytype) void {
        self.inner.debug(fmt, args);
    }

    pub fn info(self: *LegacyLogger, comptime fmt: []const u8, args: anytype) void {
        self.inner.info(fmt, args);
    }

    pub fn warn(self: *LegacyLogger, comptime fmt: []const u8, args: anytype) void {
        self.inner.warn(fmt, args);
    }

    pub fn err(self: *LegacyLogger, comptime fmt: []const u8, args: anytype) void {
        self.inner.@"error"(fmt, args);
    }

    pub fn logWithTimestamp(self: *LegacyLogger, comptime fmt: []const u8, args: anytype) void {
        // Format directly without level prefix for custom logging
        var msg_buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

        // Write directly to backend
        if (self.inner.backend) |backend| {
            const log_line = std.fmt.allocPrint(self.allocator, "{s}\n", .{message}) catch return;
            defer self.allocator.free(log_line);
            backend.write(log_line) catch {};
        }

        // Also print to console
        std.debug.print("{s}\n", .{message});
    }

    pub fn access(
        self: *LegacyLogger,
        remote_addr: []const u8,
        method: []const u8,
        path: []const u8,
        protocol: []const u8,
        status: u16,
        bytes_sent: usize,
        user_agent: []const u8,
        duration_us: i64,
    ) void {
        self.inner.access(remote_addr, method, path, protocol, status, bytes_sent, user_agent, duration_us);
    }
};

// Backward compatibility tests
test "logger basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var logger = try Logger.init(allocator, .info, null);
    defer logger.deinit();

    logger.info("Test message: {s}", .{"hello"});
    logger.debug("This should not appear", .{});
}

test "logger with file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try tmp_dir.dir.realpath(".", &log_path_buf);
    const full_log_path = try std.fmt.allocPrint(allocator, "{s}/test_log.txt", .{log_path});
    defer allocator.free(full_log_path);

    var logger = try Logger.init(allocator, .debug, full_log_path);
    defer logger.deinit();

    logger.info("Test file logging", .{});
}

test "logger json format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try tmp_dir.dir.realpath(".", &log_path_buf);
    const full_log_path = try std.fmt.allocPrint(allocator, "{s}/json_test.log", .{log_path});
    defer allocator.free(full_log_path);

    var logger = try Logger.initWithFormat(allocator, .info, full_log_path, .json);
    defer logger.deinit();

    logger.info("Test JSON logging", .{});

    // Read the log file and verify JSON format
    const file = try std.fs.cwd().openFile(full_log_path, .{});
    defer file.close();

    var read_buf: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&read_buf);
    const content = read_buf[0..bytes_read];

    // Verify JSON structure
    try testing.expect(std.mem.indexOf(u8, content, "\"timestamp\":") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"level\":\"info\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"message\":\"Test JSON logging\"") != null);
}

test "logger with request id" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try tmp_dir.dir.realpath(".", &log_path_buf);
    const full_log_path = try std.fmt.allocPrint(allocator, "{s}/reqid_test.log", .{log_path});
    defer allocator.free(full_log_path);

    var logger = try Logger.initWithFormat(allocator, .info, full_log_path, .json);
    defer logger.deinit();

    logger.logWithRequestId(.info, "abc123-xyz", "Test with request ID", .{});

    // Read the log file and verify request ID is included
    const file = try std.fs.cwd().openFile(full_log_path, .{});
    defer file.close();

    var read_buf: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&read_buf);
    const content = read_buf[0..bytes_read];

    try testing.expect(std.mem.indexOf(u8, content, "\"request_id\":\"abc123-xyz\"") != null);
}

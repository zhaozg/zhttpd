//! Logger Module
//!
//! High-performance, extensible logger with the following features:
//! - Async logging with ordered message delivery
//! - Zero-allocation hot path using stack buffers
//! - Pluggable backends (file, console, custom)
//! - Thread-safe operation
//! - Support for text and JSON formats
//! - std.log compatibility
//! - Configurable console output
//!
//! ## Usage
//!
//! ```zig
//! const logger_mod = @import("logger/logger.zig");
//! const FileBackend = logger_mod.FileBackend;
//! const LoggerConfig = logger_mod.LoggerConfig;
//!
//! // Create file backend
//! const file_backend = try FileBackend.init(allocator, "app.log");
//!
//! // Configure logger
//! const config = LoggerConfig{
//!     .level = .info,
//!     .format = .json,
//!     .enable_console = true,
//!     .enable_async = true,
//! };
//!
//! // Initialize logger
//! var logger = try Logger.init(testing.io, allocator, config, file_backend.backend());
//! defer logger.deinit();
//!
//! // Use the logger
//! logger.info("Application started", .{});
//! ```

const std = @import("std");

// Re-export components
const impl = @import("impl.zig");
pub const Backend = impl.Backend;
pub const FileBackend = impl.FileBackend;
pub const ConsoleBackend = impl.ConsoleBackend;
pub const MultiBackend = impl.MultiBackend;
pub const LogLevel = impl.LogLevel;
pub const LogFormat = impl.LogFormat;
pub const LoggerConfig = impl.LoggerConfig;
pub const Logger = impl.Logger;

// Re-export std.log compatibility function
pub const logFn = impl.logFn;
pub const setGlobalLogger = impl.setGlobalLogger;
pub const clearGlobalLogger = impl.clearGlobalLogger;

// Backward compatibility: old API that wraps new implementation
pub fn init(io: std.Io, allocator: std.mem.Allocator, level: LogLevel, log_file_path: ?[]const u8) !Logger {
    return initWithFormat(io, allocator, level, log_file_path, .text);
}

pub fn initWithFormat(io: std.Io, allocator: std.mem.Allocator, level: LogLevel, log_file_path: ?[]const u8, format: LogFormat) !Logger {
    var backend: ?Backend = null;

    if (log_file_path) |path| {
        const file_backend = try FileBackend.init(io, allocator, path);
        backend = file_backend.backend();
        errdefer backend.?.deinit();
    }

    const config = LoggerConfig{
        .level = level,
        .format = format,
        .enable_console = true,
        .enable_async = false,
    };

    return try Logger.init(io, allocator, config, backend);
}

// Tests
test "logger basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var logger = try init(allocator, .info, null);
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

    var logger = try init(allocator, .debug, full_log_path);
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

    var logger = try initWithFormat(allocator, .info, full_log_path, .json);
    defer logger.deinit();

    logger.info("Test JSON logging", .{});

    const file = try std.fs.cwd().openFile(full_log_path, .{});
    defer file.close();

    var read_buf: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&read_buf);
    const content = read_buf[0..bytes_read];

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

    var logger = try initWithFormat(allocator, .info, full_log_path, .json);
    defer logger.deinit();

    logger.logWithRequestId(.info, "abc123-xyz", "Test with request ID", .{});

    const file = try std.fs.cwd().openFile(full_log_path, .{});
    defer file.close();

    var read_buf: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&read_buf);
    const content = read_buf[0..bytes_read];

    try testing.expect(std.mem.indexOf(u8, content, "\"request_id\":\"abc123-xyz\"") != null);
}

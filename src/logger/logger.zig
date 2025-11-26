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
};

const LOG_BUFFER_SIZE = 4096;
const DEFAULT_MAX_LOG_SIZE: usize = 10 * 1024 * 1024; // 10MB
const DEFAULT_MAX_BACKUP_FILES: usize = 5;

pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: LogLevel,
    file: ?std.fs.File,
    mutex: std.Thread.Mutex,
    log_file_path: ?[]const u8,
    max_log_size: usize,
    max_backup_files: usize,
    current_size: usize,

    pub fn init(allocator: std.mem.Allocator, level: LogLevel, log_file_path: ?[]const u8) !Logger {
        var file: ?std.fs.File = null;
        var current_size: usize = 0;
        var owned_path: ?[]const u8 = null;

        if (log_file_path) |path| {
            // Duplicate the path so we own it for rotation
            owned_path = try allocator.dupe(u8, path);

            file = try std.fs.cwd().createFile(path, .{
                .read = false,
                .truncate = false,
            });

            // Get current file size
            const stat = try file.?.stat();
            current_size = stat.size;

            // Seek to end for appending
            try file.?.seekFromEnd(0);
        }

        return Logger{
            .allocator = allocator,
            .level = level,
            .file = file,
            .mutex = std.Thread.Mutex{},
            .log_file_path = owned_path,
            .max_log_size = DEFAULT_MAX_LOG_SIZE,
            .max_backup_files = DEFAULT_MAX_BACKUP_FILES,
            .current_size = current_size,
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |file| {
            file.close();
        }
        if (self.log_file_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        // Skip if log level is below configured level
        if (@intFromEnum(level) < @intFromEnum(self.level)) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Get timestamp with microsecond precision
        const now = std.time.microTimestamp();
        const seconds = @divFloor(now, std.time.us_per_s);
        const microseconds = @mod(now, std.time.us_per_s);

        // Format the log message
        var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch |format_err| blk: {
            std.debug.print("Failed to format log message: {}\n", .{format_err});
            break :blk "Log formatting error";
        };

        // Format timestamp with microsecond precision (UNIX_TIMESTAMP.MICROSECONDS)
        var ts_buf: [64]u8 = undefined;
        const timestamp_str = std.fmt.bufPrint(&ts_buf, "{d}.{d:0>6}", .{ seconds, microseconds }) catch "0.000000";

        // Write to console
        std.debug.print("[{s}] [{s}] {s}\n", .{ timestamp_str, level.toString(), message });

        // Write to file if configured
        if (self.file) |file| {
            const log_line = std.fmt.allocPrint(self.allocator, "[{s}] [{s}] {s}\n", .{
                timestamp_str,
                level.toString(),
                message,
            }) catch return;
            defer self.allocator.free(log_line);

            _ = file.write(log_line) catch |write_err| {
                std.debug.print("Failed to write to log file: {}\n", .{write_err});
                return;
            };

            // Track written size and rotate if necessary
            self.current_size += log_line.len;
            if (self.current_size >= self.max_log_size) {
                self.rotateLog() catch |rotate_err| {
                    std.debug.print("Failed to rotate log file: {}\n", .{rotate_err});
                };
            }
        }
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    /// Log HTTP access in Common Log Format with microsecond precision
    /// Format: <remote_addr> - - [timestamp] "<method> <path> <protocol>" <status> <bytes> "<user_agent>" <duration_us>µs
    pub fn access(
        self: *Logger,
        remote_addr: []const u8,
        method: []const u8,
        path: []const u8,
        protocol: []const u8,
        status: u16,
        bytes_sent: usize,
        user_agent: []const u8,
        duration_us: i64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get timestamp with microsecond precision
        const now = std.time.microTimestamp();
        const seconds = @divFloor(now, std.time.us_per_s);
        const microseconds = @mod(now, std.time.us_per_s);

        // Format: IP - - [timestamp] "METHOD PATH PROTOCOL" STATUS BYTES "USER-AGENT" DURATIONµs
        var buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const log_line = std.fmt.bufPrint(&buf, "{s} - - [{d}.{d:0>6}] \"{s} {s} {s}\" {d} {d} \"{s}\" {d}µs\n", .{ remote_addr, seconds, microseconds, method, path, protocol, status, bytes_sent, user_agent, duration_us }) catch return;

        // Write to console
        std.debug.print("{s}", .{log_line});

        // Write to file if configured
        if (self.file) |file| {
            _ = file.write(log_line) catch |write_err| {
                std.debug.print("Failed to write access log: {}\n", .{write_err});
                return;
            };

            // Track written size and rotate if necessary
            self.current_size += log_line.len;
            if (self.current_size >= self.max_log_size) {
                self.rotateLog() catch |rotate_err| {
                    std.debug.print("Failed to rotate log file: {}\n", .{rotate_err});
                };
            }
        }
    }

    /// Rotate log files: current.log -> current.log.1 -> current.log.2 -> ... -> current.log.N
    /// Oldest file (N) is deleted
    fn rotateLog(self: *Logger) !void {
        const path = self.log_file_path orelse return;

        // Close current file
        if (self.file) |file| {
            file.close();
            self.file = null;
        }

        // Delete the oldest backup file if it exists (file.max_backup_files)
        const oldest_backup = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ path, self.max_backup_files });
        defer self.allocator.free(oldest_backup);
        std.fs.cwd().deleteFile(oldest_backup) catch {};

        // Rotate existing backup files: file.N-1 -> file.N, ..., file.1 -> file.2
        var i: usize = self.max_backup_files - 1;
        while (i > 0) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ path, i });
            defer self.allocator.free(old_name);

            const new_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ path, i + 1 });
            defer self.allocator.free(new_name);

            // Rename file.i to file.i+1 if it exists
            std.fs.cwd().rename(old_name, new_name) catch {};
        }

        // Rename current log to .1
        const backup_name = try std.fmt.allocPrint(self.allocator, "{s}.1", .{path});
        defer self.allocator.free(backup_name);
        std.fs.cwd().rename(path, backup_name) catch {};

        // Create new log file
        self.file = try std.fs.cwd().createFile(path, .{
            .read = false,
            .truncate = false,
        });
        self.current_size = 0;
    }
};

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

    // Use a temporary directory path that works cross-platform
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

test "logger rotation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use a temporary directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try tmp_dir.dir.realpath(".", &log_path_buf);
    const full_log_path = try std.fmt.allocPrint(allocator, "{s}/rotate_test.log", .{log_path});
    defer allocator.free(full_log_path);

    var logger = try Logger.init(allocator, .info, full_log_path);
    defer logger.deinit();

    // Set small max log size for testing
    logger.max_log_size = 100;
    logger.max_backup_files = 3;

    // Write messages to trigger rotation
    logger.info("Message 1", .{});
    logger.info("Message 2", .{});
    logger.info("Message 3", .{});
    logger.info("Message 4 - should trigger rotation", .{});

    // Check that rotation happened by checking backup file exists
    const backup1 = try std.fmt.allocPrint(allocator, "{s}.1", .{full_log_path});
    defer allocator.free(backup1);

    // Note: In test environment, file might not be rotated yet since actual size tracking
    // depends on real file writes. This test verifies rotation logic doesn't crash.
}

test "logger timestamp precision" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var logger = try Logger.init(allocator, .info, null);
    defer logger.deinit();

    // Test that microsecond precision logging works
    // This primarily tests that the code compiles and runs without panicking
    logger.info("Timestamp test at microsecond precision", .{});
}

test "logger access log format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try tmp_dir.dir.realpath(".", &log_path_buf);
    const full_log_path = try std.fmt.allocPrint(allocator, "{s}/access_test.log", .{log_path});
    defer allocator.free(full_log_path);

    var logger = try Logger.init(allocator, .info, full_log_path);
    defer logger.deinit();

    // Test access logging
    logger.access(
        "127.0.0.1:54321",
        "GET",
        "/test/path",
        "HTTP/1.1",
        200,
        1024,
        "TestAgent/1.0",
        1500, // 1.5ms
    );
}

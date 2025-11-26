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

pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: LogLevel,
    file: ?std.fs.File,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, level: LogLevel, log_file_path: ?[]const u8) !Logger {
        var file: ?std.fs.File = null;

        if (log_file_path) |path| {
            file = try std.fs.cwd().createFile(path, .{
                .read = false,
                .truncate = false,
            });
            // Seek to end for appending
            try file.?.seekFromEnd(0);
        }

        return Logger{
            .allocator = allocator,
            .level = level,
            .file = file,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |file| {
            file.close();
        }
    }

    pub fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        // Skip if log level is below configured level
        if (@intFromEnum(level) < @intFromEnum(self.level)) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const timestamp = std.time.timestamp();

        // Format the log message
        var buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch |err| blk: {
            std.debug.print("Failed to format log message: {}\n", .{err});
            break :blk "Log formatting error";
        };

        // Use a simplified timestamp for logging - just epoch seconds
        // TODO: Consider using a proper datetime library for human-readable timestamps
        const ts = @as(u64, @intCast(timestamp));

        // Write to console
        std.debug.print("[{d}] [{s}] {s}\n", .{ ts, level.toString(), message });

        // Write to file if configured
        if (self.file) |file| {
            const log_line = std.fmt.allocPrint(self.allocator, "[{d}] [{s}] {s}\n", .{
                ts,
                level.toString(),
                message,
            }) catch return;
            defer self.allocator.free(log_line);

            _ = file.write(log_line) catch |err| {
                std.debug.print("Failed to write to log file: {}\n", .{err});
            };
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

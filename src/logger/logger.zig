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
        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch |err| blk: {
            std.debug.print("Failed to format log message: {}\n", .{err});
            break :blk "Log formatting error";
        };

        // Get timestamp string
        const epoch_seconds = @as(u64, @intCast(timestamp));
        const day_seconds = 86400;
        const hour_seconds = 3600;
        const minute_seconds = 60;

        const days_since_epoch = epoch_seconds / day_seconds;
        const seconds_today = epoch_seconds % day_seconds;
        const hours = seconds_today / hour_seconds;
        const minutes = (seconds_today % hour_seconds) / minute_seconds;
        const seconds = seconds_today % minute_seconds;

        // Simple date calculation (approximate)
        const year = @as(u32, @intCast(1970 + days_since_epoch / 365));
        const month = @as(u32, @intCast((days_since_epoch % 365) / 30 + 1));
        const day = @as(u32, @intCast((days_since_epoch % 365) % 30 + 1));

        // Write to console
        std.debug.print("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] [{s}] {s}\n", .{
            year, month, day, hours, minutes, seconds, level.toString(), message,
        });

        // Write to file if configured
        if (self.file) |file| {
            const log_line = std.fmt.allocPrint(self.allocator, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] [{s}] {s}\n", .{
                year, month, day, hours, minutes, seconds, level.toString(), message,
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

    const log_path = "/tmp/test_log.txt";

    // Clean up any existing log file
    std.fs.cwd().deleteFile(log_path) catch {};

    var logger = try Logger.init(allocator, .debug, log_path);
    defer logger.deinit();

    logger.info("Test file logging", .{});

    // Clean up
    std.fs.cwd().deleteFile(log_path) catch {};
}

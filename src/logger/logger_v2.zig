const std = @import("std");
const backend_mod = @import("backend.zig");
const formatter_mod = @import("formatter.zig");
const async_queue_mod = @import("async_queue.zig");

pub const Backend = backend_mod.Backend;
pub const FileBackend = backend_mod.FileBackend;
pub const ConsoleBackend = backend_mod.ConsoleBackend;
pub const MultiBackend = backend_mod.MultiBackend;

pub const LogLevel = formatter_mod.LogLevel;
pub const LogFormat = formatter_mod.LogFormat;

const LOG_BUFFER_SIZE = 4096;
const ASYNC_QUEUE_SIZE = 1024;

/// Log message for async queue
const LogMessage = struct {
    data: [LOG_BUFFER_SIZE]u8,
    len: usize,

    fn init(data: []const u8) LogMessage {
        var msg = LogMessage{
            .data = undefined,
            .len = @min(data.len, LOG_BUFFER_SIZE),
        };
        @memcpy(msg.data[0..msg.len], data[0..msg.len]);
        return msg;
    }

    fn slice(self: *const LogMessage) []const u8 {
        return self.data[0..self.len];
    }
};

const AsyncQueue = async_queue_mod.AsyncQueue(LogMessage, ASYNC_QUEUE_SIZE);

/// Configuration for logger
pub const LoggerConfig = struct {
    level: LogLevel = .info,
    format: LogFormat = .text,
    enable_console: bool = true,
    enable_async: bool = false,
};

/// High-performance logger with async support, zero-allocation hot path, and extensibility
pub const Logger = struct {
    allocator: std.mem.Allocator,
    config: LoggerConfig,
    backend: ?Backend,
    console_backend: ?Backend,
    async_queue: ?*AsyncQueue,
    writer_thread: ?std.Thread,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig, backend: ?Backend) !Logger {
        var logger = Logger{
            .allocator = allocator,
            .config = config,
            .backend = backend,
            .console_backend = null,
            .async_queue = null,
            .writer_thread = null,
            .mutex = .{},
        };

        // Initialize console backend if enabled
        if (config.enable_console) {
            const console = try ConsoleBackend.init(allocator);
            logger.console_backend = console.backend();
        }

        // Initialize async queue and writer thread if enabled
        if (config.enable_async and backend != null) {
            const queue = try allocator.create(AsyncQueue);
            queue.* = AsyncQueue.init();
            logger.async_queue = queue;

            logger.writer_thread = try std.Thread.spawn(.{}, writerThreadFn, .{&logger});
        }

        return logger;
    }

    pub fn deinit(self: *Logger) void {
        // Signal shutdown for async logging
        if (self.async_queue) |queue| {
            queue.signalShutdown();
        }

        // Wait for writer thread to finish
        if (self.writer_thread) |thread| {
            thread.join();
        }

        // Clean up async queue
        if (self.async_queue) |queue| {
            self.allocator.destroy(queue);
        }

        // Clean up backends
        if (self.backend) |backend| {
            backend.deinit();
        }
        if (self.console_backend) |console| {
            console.deinit();
        }
    }

    /// Writer thread function for async logging
    fn writerThreadFn(self: *Logger) void {
        while (true) {
            const msg_opt = if (self.async_queue) |queue| queue.dequeue() else null;
            const msg = msg_opt orelse break; // Shutdown signal

            if (self.backend) |backend| {
                backend.write(msg.slice()) catch |err| {
                    std.debug.print("Logger backend write error: {}\n", .{err});
                };
            }
        }

        // Final flush
        if (self.backend) |backend| {
            backend.flush() catch |err| {
                std.debug.print("Logger backend flush error: {}\n", .{err});
            };
        }
    }

    /// Log a message with the specified level
    pub fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        self.logWithRequestId(level, null, fmt, args);
    }

    /// Log with optional request ID for tracing
    pub fn logWithRequestId(self: *Logger, level: LogLevel, request_id: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        // Skip if log level is below configured level
        if (@intFromEnum(level) < @intFromEnum(self.config.level)) {
            return;
        }

        // Format the message
        var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch |err| blk: {
            std.debug.print("Failed to format log message: {}\n", .{err});
            break :blk "Log formatting error";
        };

        // Format the complete log line
        var log_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const log_line = formatter_mod.formatMessage(&log_buf, level, self.config.format, message, request_id) catch |err| blk: {
            std.debug.print("Failed to format log line: {}\n", .{err});
            break :blk message;
        };

        // Write to console if enabled (always synchronous for immediate feedback)
        if (self.console_backend) |console| {
            // Use text format for console even if file uses JSON
            var console_buf: [LOG_BUFFER_SIZE]u8 = undefined;
            const console_line = if (self.config.format == .json)
                formatter_mod.formatMessage(&console_buf, level, .text, message, request_id) catch log_line
            else
                log_line;

            console.write(console_line) catch |err| {
                std.debug.print("Console write error: {}\n", .{err});
            };
        }

        // Write to backend (async or sync based on configuration)
        if (self.backend != null) {
            if (self.async_queue) |queue| {
                // Async mode: enqueue for background writing
                const msg = LogMessage.init(log_line);
                if (!queue.tryEnqueue(msg)) {
                    // Queue is full, fall back to synchronous write
                    self.writeSync(log_line);
                }
            } else {
                // Sync mode: write directly
                self.writeSync(log_line);
            }
        }
    }

    fn writeSync(self: *Logger, msg: []const u8) void {
        if (self.backend) |backend| {
            backend.write(msg) catch |write_err| {
                std.debug.print("Logger write error: {}\n", .{write_err});
            };
        }
    }

    /// Flush all pending log messages
    pub fn flush(self: *Logger) void {
        // Wait for async queue to drain if enabled
        if (self.async_queue) |queue| {
            while (!queue.isEmpty()) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        // Flush backend
        if (self.backend) |backend| {
            backend.flush() catch |flush_err| {
                std.debug.print("Logger flush error: {}\n", .{flush_err});
            };
        }

        // Flush console
        if (self.console_backend) |console| {
            console.flush() catch |flush_err| {
                std.debug.print("Console flush error: {}\n", .{flush_err});
            };
        }
    }

    /// Convenience methods for different log levels
    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn @"error"(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    /// Log HTTP access in Common Log Format
    /// This is a specialized logger for HTTP access logs
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
        const duration_ms = @as(f64, @floatFromInt(duration_us)) / 1000.0;
        const timestamp_str = formatter_mod.formatTimestamp();

        var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const log_line = std.fmt.bufPrint(&msg_buf, "{s} - - [{s}] \"{s} {s} {s}\" {d} {d} \"{s}\" {d:.2}ms\n", .{
            remote_addr,
            &timestamp_str,
            method,
            path,
            protocol,
            status,
            bytes_sent,
            user_agent,
            duration_ms,
        }) catch return;

        // Access logs bypass console backend and go directly to file
        if (self.backend != null) {
            if (self.async_queue) |queue| {
                const msg = LogMessage.init(log_line);
                _ = queue.tryEnqueue(msg);
            } else {
                self.writeSync(log_line);
            }
        }
    }
};

/// Compatibility function for std.log integration
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope; // TODO: could add scope to log message

    const our_level: LogLevel = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };

    // This requires a global logger instance to be set
    // For now, just print to stderr
    var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, format, args) catch return;

    var log_buf: [LOG_BUFFER_SIZE]u8 = undefined;
    const log_line = formatter_mod.formatMessage(&log_buf, our_level, .text, message, null) catch return;

    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(log_line) catch {};
}

test "Logger basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = LoggerConfig{
        .level = .info,
        .enable_console = false,
        .enable_async = false,
    };

    var logger = try Logger.init(allocator, config, null);
    defer logger.deinit();

    logger.info("Test message: {s}", .{"hello"});
    logger.debug("This should not appear", .{});
}

test "Logger with file backend" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/test.log", .{dir_path});
    defer allocator.free(log_path);

    const file_backend = try FileBackend.init(allocator, log_path);
    const config = LoggerConfig{
        .level = .debug,
        .enable_console = false,
        .enable_async = false,
    };

    var logger = try Logger.init(allocator, config, file_backend.backend());
    defer logger.deinit();

    logger.info("Test file logging", .{});
    logger.flush();
}

test "Logger async mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/async_test.log", .{dir_path});
    defer allocator.free(log_path);

    const file_backend = try FileBackend.init(allocator, log_path);
    const config = LoggerConfig{
        .level = .info,
        .enable_console = false,
        .enable_async = true,
    };

    var logger = try Logger.init(allocator, config, file_backend.backend());
    defer logger.deinit();

    // Log multiple messages
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        logger.info("Async message {d}", .{i});
    }

    // Wait for messages to be written
    logger.flush();
}

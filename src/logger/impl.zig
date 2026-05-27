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

/// Global logger instance for std.log integration
/// Must be set via setGlobalLogger() to enable std.log compatibility
var global_logger: ?*Logger = null;
var global_logger_mutex: std.atomic.Mutex = .unlocked;

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
    console_backend_ptr: ?*ConsoleBackend,
    async_queue: ?*AsyncQueue,
    writer_thread: ?std.Thread,
    mutex: std.atomic.Mutex,
    flush_semaphore: std.Io.Semaphore,
    io: std.Io,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: LoggerConfig, backend: ?Backend) !Logger {
        var logger = Logger{
            .allocator = allocator,
            .config = config,
            .backend = backend,
            .console_backend_ptr = null,
            .async_queue = null,
            .writer_thread = null,
            .mutex = .unlocked,
            .flush_semaphore = .{},
            .io = io,
        };

        // Initialize console backend if enabled
        if (config.enable_console) {
            const console = try ConsoleBackend.init(allocator);
            logger.console_backend_ptr = console;
        }
        errdefer if (logger.console_backend_ptr) |console| {
            const console_allocator = console.allocator;
            console_allocator.destroy(console);
        };

        // Initialize async queue and writer thread if enabled
        if (config.enable_async and backend != null) {
            const queue = try allocator.create(AsyncQueue);
            errdefer allocator.destroy(queue);

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
        if (self.console_backend_ptr) |console| {
            const allocator = console.allocator;
            allocator.destroy(console);
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

            // Signal if queue is now empty (for flush)
            if (self.async_queue) |queue| {
                if (queue.isEmpty()) {
                    self.flush_semaphore.post(self.io);
                }
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
        const log_line = formatter_mod.formatMessage(self.io, &log_buf, level, self.config.format, message, request_id) catch |err| blk: {
            std.debug.print("Failed to format log line: {}\n", .{err});
            break :blk message;
        };

        // Write to console if enabled (always synchronous for immediate feedback)
        if (self.console_backend_ptr) |console| {
            // Use text format for console even if file uses JSON
            var console_buf: [LOG_BUFFER_SIZE]u8 = undefined;
            const console_line = if (self.config.format == .json)
                formatter_mod.formatMessage(self.io, &console_buf, level, .text, message, request_id) catch log_line
            else
                log_line;

            const console_backend = console.backend();
            console_backend.write(console_line) catch |err| {
                std.debug.print("Console write error: {}\n", .{err});
            };
        }

        // Write to backend (async or sync based on configuration)
        if (self.backend != null) {
            if (self.async_queue) |queue| {
                // Async mode: enqueue for background writing
                const msg = LogMessage.init(log_line);
                if (!queue.tryEnqueue(msg)) {
                    // Queue is full, log warning and drop message
                    std.debug.print("Logger queue full, dropping message\n", .{});
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
            // Use semaphore-based waiting with timeout
            const timeout_ns = 5 * std.time.ns_per_s; // 5 second timeout
            const start = std.Io.Clock.now(.awake, self.io).toNanoseconds();

            // Wait for queue to be empty
            while (!queue.isEmpty()) {
                const elapsed = std.Io.Clock.now(.awake, self.io).toNanoseconds() - start;
                if (elapsed > timeout_ns) {
                    const remaining = queue.len();
                    std.debug.print("Logger flush timeout: {d} messages remaining in queue\n", .{remaining});
                    break;
                }

                // Wait on semaphore with timeout (use timedWait if available, otherwise wait with check)
                // Note: std.Thread.Semaphore doesn't have timedWait, so we use a hybrid approach
                if (!queue.isEmpty()) {
                    // Wait for signal from writer thread or timeout
                    const wait_time_ns = 100 * std.time.ns_per_ms; // 100ms per iteration
                    const iteration_start = std.Io.Clock.now(.awake, self.io).toNanoseconds();

                    // Try to wait on semaphore (non-blocking attempt)
                    while (std.Io.Clock.now(.awake, self.io).toNanoseconds() - iteration_start < wait_time_ns) {
                        if (queue.isEmpty()) break;
                        self.flush_semaphore.wait(); // Wait for signal
                        break;
                    }
                }
            }
        }

        // Flush backend
        if (self.backend) |backend| {
            backend.flush() catch |flush_err| {
                std.debug.print("Logger flush error: {}\n", .{flush_err});
            };
        }

        // Flush console
        if (self.console_backend_ptr) |console| {
            const console_backend = console.backend();
            console_backend.flush() catch |flush_err| {
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
        const timestamp_str = formatter_mod.formatTimestamp(self.io);

        // Sanitize fields to prevent log injection
        var sanitized_path: [LOG_BUFFER_SIZE]u8 = undefined;
        const safe_path = sanitizeLogField(path, &sanitized_path);

        var sanitized_ua: [LOG_BUFFER_SIZE]u8 = undefined;
        const safe_ua = sanitizeLogField(user_agent, &sanitized_ua);

        var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const log_line = std.fmt.bufPrint(&msg_buf, "{s} - - [{s}] \"{s} {s} {s}\" {d} {d} \"{s}\" {d:.2}ms\n", .{
            remote_addr,
            &timestamp_str,
            method,
            safe_path,
            protocol,
            status,
            bytes_sent,
            safe_ua,
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

    /// Sanitize log field by replacing newlines and other control characters
    fn sanitizeLogField(input: []const u8, buf: []u8) []const u8 {
        var pos: usize = 0;
        for (input) |c| {
            if (pos >= buf.len) break;
            // Replace control characters with spaces
            if (c < 32 or c == 127) {
                buf[pos] = ' ';
            } else {
                buf[pos] = c;
            }
            pos += 1;
        }
        return buf[0..pos];
    }
};

/// Set global logger for std.log integration
/// This allows std.log.* calls to use the configured logger
pub fn setGlobalLogger(logger: *Logger) void {
    while (!global_logger_mutex.tryLock()) {}
    defer global_logger_mutex.unlock();
    global_logger = logger;
}

/// Clear global logger
pub fn clearGlobalLogger() void {
    while (!global_logger_mutex.tryLock()) {}
    defer global_logger_mutex.unlock();
    global_logger = null;
}

/// Compatibility function for std.log integration
/// To use this, call setGlobalLogger() with your logger instance,
/// then configure your build.zig to use this as the log function:
///
/// ```zig
/// pub const std_options = .{
///     .logFn = @import("logger/logger.zig").logFn,
/// };
/// ```
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_name = scope;

    const our_level: LogLevel = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };

    // Try to use global logger if set
    while (!global_logger_mutex.tryLock()) {}
    const logger_copy = global_logger;
    global_logger_mutex.unlock();

    if (logger_copy) |log| {
        // Format message with scope
        if (std.mem.eql(u8, scope, "default")) {
            var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
            const message = std.fmt.bufPrint(&msg_buf, format, args) catch return;
            log.log(our_level, "{s}", .{message});
        } else {
            // Format with scope prefix
            var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
            const scope_prefix = std.fmt.bufPrint(&msg_buf, "({s}) ", .{scope_name}) catch return;
            const remaining = msg_buf[scope_prefix.len..];
            const message_part = std.fmt.bufPrint(remaining, format, args) catch return;
            const full_message = msg_buf[0 .. scope_prefix.len + message_part.len];
            log.log(our_level, "{s}", .{full_message});
        }
    } else {
        // Fallback: print directly to stderr
        var msg_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const message = if (std.mem.eql(u8, scope, "default"))
            std.fmt.bufPrint(&msg_buf, format, args) catch return
        else blk: {
            const scope_prefix = std.fmt.bufPrint(&msg_buf, "({s}) ", .{scope_name}) catch return;
            const remaining = msg_buf[scope_prefix.len..];
            const message_part = std.fmt.bufPrint(remaining, format, args) catch return;
            break :blk msg_buf[0 .. scope_prefix.len + message_part.len];
        };

        var log_buf: [LOG_BUFFER_SIZE]u8 = undefined;
        const log_line = formatter_mod.formatMessage(&log_buf, our_level, .text, message, null) catch return;

        const stderr = std.io.getStdErr().writer();
        _ = stderr.write(log_line) catch {};
    }
}

test "Logger basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = LoggerConfig{
        .level = .info,
        .enable_console = false,
        .enable_async = false,
    };

    var logger = try Logger.init(testing.io, allocator, config, null);
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

    var logger = try Logger.init(testing.io, allocator, config, file_backend.backend());
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

    var logger = try Logger.init(testing.io, allocator, config, file_backend.backend());
    defer logger.deinit();

    // Log multiple messages
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        logger.info("Async message {d}", .{i});
    }

    // Wait for messages to be written
    logger.flush();
}

test "Logger access log format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/access_test.log", .{dir_path});
    defer allocator.free(log_path);

    const file_backend = try FileBackend.init(allocator, log_path);
    const config = LoggerConfig{
        .level = .info,
        .enable_console = false,
        .enable_async = false,
    };

    var logger = try Logger.init(testing.io, allocator, config, file_backend.backend());
    defer logger.deinit();

    logger.access(
        "127.0.0.1:12345",
        "GET",
        "/test/path",
        "HTTP/1.1",
        200,
        1024,
        "TestAgent/1.0",
        1500,
    );
    logger.flush();

    // Verify access log format
    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    var buf: [2048]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = buf[0..n];

    try testing.expect(std.mem.indexOf(u8, content, "127.0.0.1:12345") != null);
    try testing.expect(std.mem.indexOf(u8, content, "GET /test/path HTTP/1.1") != null);
    try testing.expect(std.mem.indexOf(u8, content, "200 1024") != null);
    try testing.expect(std.mem.indexOf(u8, content, "TestAgent/1.0") != null);
}

test "std.log integration with global logger" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/stdlog_test.log", .{dir_path});
    defer allocator.free(log_path);

    const file_backend = try FileBackend.init(allocator, log_path);
    const config = LoggerConfig{
        .level = .info,
        .enable_console = false,
        .enable_async = false,
    };

    var logger = try Logger.init(testing.io, allocator, config, file_backend.backend());
    defer logger.deinit();

    // Set global logger
    setGlobalLogger(&logger);
    defer clearGlobalLogger();

    // Test logFn with scope
    logFn(.info, .test_scope, "Test message with scope", .{});
    logger.flush();

    // Verify log contains scope
    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = buf[0..n];

    try testing.expect(std.mem.indexOf(u8, content, "(test_scope)") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Test message with scope") != null);
}

test "std.log integration without global logger" {
    // Test that logFn works even without global logger (fallback to stderr)
    // Just verify it doesn't crash
    logFn(.info, .default, "Fallback message", .{});
}

# Logger Module Documentation

The logger module in zhttpd has been refactored to provide high performance, extensibility, and advanced features inspired by modern logging libraries.

## Features

### Core Features
- **Modular Architecture**: Separate backends, formatters, and core logger
- **Async Logging**: Optional background thread for high-throughput logging
- **Zero Allocations**: Stack-based buffers in hot path
- **Thread-Safe**: Mutex-protected operations for concurrent access
- **Multiple Backends**: File, console, or custom destinations
- **Format Support**: Text and JSON output formats
- **Log Rotation**: Automatic file rotation with configurable size limits
- **Request Tracing**: Optional request ID tracking

### Advanced Features
- **FIFO Ordering**: Async logging maintains message order
- **Pluggable Backends**: Easy to add custom log destinations
- **Configurable Console**: Independent console output control
- **Backward Compatible**: Legacy API maintained for existing code

## Architecture

### Components

```
logger/
├── logger.zig        # Main entry point with backward-compatible API
├── impl.zig          # Core logger implementation
├── backend.zig       # Backend interface and implementations
├── formatter.zig     # Message formatting (text/JSON)
└── async_queue.zig   # Bounded FIFO queue for async mode
```

### Backend Interface

The `Backend` interface allows plugging in custom log destinations:

```zig
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, msg: []const u8) anyerror!void,
        flush: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };
};
```

## Usage

### Basic Usage

The simple API provides backward compatibility:

```zig
const logger_mod = @import("logger/logger.zig");

// Initialize with file output
var logger = try logger_mod.init(allocator, .info, "app.log");
defer logger.deinit();

// Log at different levels
logger.debug("Debug message: {d}", .{42});
logger.info("Server started on port {d}", .{8080});
logger.warn("Connection limit reached", .{});
logger.@"error"("Failed to open file: {s}", .{err});

// Log with request ID for tracing
logger.logWithRequestId(.info, "req-123", "Processing request", .{});
```

### Advanced Usage

The full API provides more control and features:

```zig
const logger_mod = @import("logger/logger.zig");
const FileBackend = logger_mod.FileBackend;
const LoggerConfig = logger_mod.LoggerConfig;
const Logger = logger_mod.Logger;

// Create a file backend
const file_backend = try FileBackend.init(allocator, "app.log");

// Configure logger
const config = LoggerConfig{
    .level = .info,
    .format = .json,
    .enable_console = true,
    .enable_async = true,  // Enable async mode
};

// Initialize logger
var logger = try Logger.init(allocator, config, file_backend.backend());
defer logger.deinit();

// Use the logger
logger.info("Application started", .{});
```

### Multiple Backends

Log to multiple destinations simultaneously:

```zig
const logger_mod = @import("logger/logger.zig");
const FileBackend = logger_mod.FileBackend;
const ConsoleBackend = logger_mod.ConsoleBackend;
const MultiBackend = logger_mod.MultiBackend;
const Backend = logger_mod.Backend;

// Create backends
const file = try FileBackend.init(allocator, "app.log");
const console = try ConsoleBackend.init(allocator);

// Allocate backends array on heap (MultiBackend will take ownership)
const backends = try allocator.alloc(Backend, 2);
backends[0] = file.backend();
backends[1] = console.backend();

const multi = try MultiBackend.init(allocator, backends);

// Use with logger
var logger = try logger_mod.Logger.init(allocator, config, multi.backend());
defer logger.deinit();
```

### std.log Integration

Integrate with Zig's standard logging interface:

```zig
const logger_mod = @import("logger/logger.zig");

// In your root source file or build configuration
pub const std_options = .{
    .logFn = logger_mod.logFn,
};

// In your application initialization
var logger = try logger_mod.init(allocator, .info, "app.log");
logger_mod.setGlobalLogger(&logger);
defer {
    logger_mod.clearGlobalLogger();
    logger.deinit();
}

// Now std.log calls will use your configured logger
const log = std.log.scoped(.myapp);
log.info("Application started", .{});  // Will include scope in output
```

### Access Logging

The logger provides specialized access logging for HTTP requests:

```zig
logger.access(
    "127.0.0.1:54321",    // Remote address
    "GET",                // Method
    "/api/users",         // Path
    "HTTP/1.1",           // Protocol
    200,                  // Status code
    1024,                 // Bytes sent
    "Mozilla/5.0",        // User agent
    1500,                 // Duration in microseconds
);
```

Output format (Common Log Format):
```
127.0.0.1:54321 - - [2025-12-03 12:34:56.789012] "GET /api/users HTTP/1.1" 200 1024 "Mozilla/5.0" 1.50ms
```

## Configuration

### YAML Configuration

Add logger configuration to your `config.yaml`:

```yaml
# Log level: debug, info, warn, err
log_level: "info"

# Main application log file (optional)
log_file: "zhttpd.log"

# HTTP access log file (optional)
access_log_file: "access.log"

# Log format: text or json
log_format: "text"

# Enable async logging for better performance
log_async: false

# Enable console output alongside file logging
log_console: true
```

### JSON vs Text Format

**Text Format** (human-readable):
```
[2025-12-03 12:34:56.789012] [INFO] Server started on port 8080
[2025-12-03 12:34:56.890123] [WARN] [req-abc123] High memory usage detected
```

**JSON Format** (machine-parsable):
```json
{"timestamp":"2025-12-03 12:34:56.789012","level":"info","message":"Server started on port 8080"}
{"timestamp":"2025-12-03 12:34:56.890123","level":"warn","request_id":"req-abc123","message":"High memory usage detected"}
```

## Performance

### Async Logging

Async logging offloads I/O to a background thread, reducing latency in the hot path:

- **Sync Mode**: ~10-50μs per log call (with file I/O)
- **Async Mode**: ~1-5μs per log call (enqueue only)

Enable async logging for high-throughput applications:

```yaml
log_async: true
```

### Zero Allocations

The hot path uses stack-based buffers:

```zig
var msg_buf: [4096]u8 = undefined;  // Stack allocation
const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch ...;
```

Only allocations:
- Logger initialization
- Backend setup
- Log rotation

### Optimization Tips

1. **Use appropriate log levels**: Set level to `info` or `warn` in production
2. **Enable async mode**: For applications with >1000 logs/second
3. **Disable console output**: In production if not needed (`log_console: false`)
4. **Use JSON format**: For structured logging pipelines
5. **Configure rotation**: Prevent unbounded log file growth

## Log Rotation

Automatic log rotation prevents disk space issues:

```zig
// Default rotation settings
const file_backend = try FileBackend.init(allocator, "app.log");
file_backend.max_size = 10 * 1024 * 1024;  // 10MB
file_backend.max_backups = 5;               // Keep 5 backups
```

Rotation sequence:
```
app.log (current)
app.log.1 (most recent backup)
app.log.2
app.log.3
app.log.4
app.log.5 (oldest backup)
```

## Custom Backends

Implement the `Backend` interface for custom destinations:

```zig
const CustomBackend = struct {
    // Your state here

    pub fn backend(self: *CustomBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .write = write,
                .flush = flush,
                .deinit = deinit,
            },
        };
    }

    fn write(ptr: *anyopaque, msg: []const u8) !void {
        const self: *CustomBackend = @ptrCast(@alignCast(ptr));
        // Implement write logic
    }

    fn flush(ptr: *anyopaque) !void {
        const self: *CustomBackend = @ptrCast(@alignCast(ptr));
        // Implement flush logic
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *CustomBackend = @ptrCast(@alignCast(ptr));
        // Cleanup
    }
};
```

## Migration Guide

### From Old Logger

The old logger API is still supported:

```zig
// Old code - still works
const logger_mod = @import("logger/logger.zig");
var logger = try logger_mod.init(allocator, .info, "app.log");
defer logger.deinit();
logger.info("Message", .{});
```

### To New Logger

To use new features, use the full API:

```zig
// New code with async support
const logger_mod = @import("logger/logger.zig");
const file_backend = try logger_mod.FileBackend.init(allocator, "app.log");
const config = logger_mod.LoggerConfig{
    .level = .info,
    .enable_async = true
};
var logger = try logger_mod.Logger.init(allocator, config, file_backend.backend());
defer logger.deinit();
logger.info("Message", .{});
```

## Best Practices

1. **Initialize once**: Create logger during application startup
2. **Use appropriate levels**:
   - `debug`: Detailed diagnostic information
   - `info`: General informational messages
   - `warn`: Warning conditions
   - `err`: Error conditions
3. **Add context**: Use request IDs for tracing related logs
4. **Flush on shutdown**: Call `logger.flush()` before exit
5. **Monitor log files**: Set up rotation and monitoring
6. **Use structured logging**: JSON format for production systems

## Thread Safety

All logger operations are thread-safe:

```zig
// Safe to call from multiple threads
const Thread1 = struct {
    fn run(logger: *Logger) void {
        logger.info("Thread 1 message", .{});
    }
};

const Thread2 = struct {
    fn run(logger: *Logger) void {
        logger.info("Thread 2 message", .{});
    }
};
```

Async mode provides additional performance benefits in multi-threaded scenarios by batching writes in the background thread.

## Testing

Test your logging setup:

```zig
test "logger basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const logger_mod = @import("logger/logger.zig");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &path_buf);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/test.log", .{dir_path});
    defer allocator.free(log_path);

    var logger = try logger_mod.init(allocator, .info, log_path);
    defer logger.deinit();

    logger.info("Test message", .{});
    logger.flush();

    // Verify log file contents
    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "Test message") != null);
}
```

## Troubleshooting

### Logs not appearing

1. Check log level configuration
2. Verify file permissions
3. Ensure logger is not prematurely deinitialized
4. Call `flush()` before checking output

### High CPU usage

1. Disable async mode if not needed
2. Reduce log verbosity
3. Check for excessive logging in hot paths

### Disk space issues

1. Configure log rotation
2. Use external log rotation tools (logrotate)
3. Set appropriate `max_size` and `max_backups`

## Future Enhancements

Planned improvements:

- [ ] SIMD optimizations for string operations
- [ ] Network backends (syslog, journald)
- [ ] Log filtering and sampling
- [ ] Performance metrics and monitoring
- [ ] Batching optimizations for async mode

## References

- [zlog](https://github.com/hendriknielaender/zlog) - Inspiration for async design
- [http.zig](https://github.com/karlseguin/http.zig) - HTTP server framework
- Zig standard library logging documentation

# zhttpd Logging System

## Overview

zhttpd includes a comprehensive, thread-safe logging system with the following features:

- **General-Purpose Logger**: Thread-safe, efficient logging core that can be used for any application logging needs
- **Structured Logging**: Multi-level logging (debug, info, warn, error)
- **High-Precision Timestamps**: Timestamps in YYYY-MM-DD HH:MM:SS.microseconds format with microsecond precision
- **Automatic Rotation**: Log files automatically rotate when reaching size limits
- **HTTP Access Logs**: Specialized logger built on the general logger for HTTP request tracking
- **Security**: Log injection prevention through input sanitization

## Architecture

The logging system has a two-layer design:

1. **Core Logger (logger.zig)**: A general-purpose, thread-safe logging implementation
   - Can be used for any application logging needs
   - Provides multi-level logging with rotation support
   - Thread-safe with mutex protection
   - Efficient timestamp formatting

2. **HTTP Access Logger**: A specialized implementation built on top of the core logger
   - Uses the same rotation and file management
   - Formats logs in Common Log Format
   - Includes request duration in milliseconds

## Configuration

### Log Levels

The `log_level` setting controls the verbosity of application logs:

```yaml
log_level: "info"  # Options: "debug", "info", "warn", "err"
```

- **debug**: Verbose debugging information (useful for development)
- **info**: General informational messages (recommended for production)
- **warn**: Warning messages only
- **err**: Error messages only (minimal logging)

### Application Log File

Configure application logging with the `log_file` option:

```yaml
log_file: "zhttpd.log"  # Path to application log file
```

Example log output:
```
[2025-11-26 07:53:49.729882] [INFO] Lua handler initialized with scripts from: ./examples/lua
[2025-11-26 07:53:49.730236] [INFO] GraphQL handler initialized
[2025-11-26 07:53:49.730401] [INFO] Starting zhttpd v0.1.0 on 0.0.0.0:8080
```

Format: `[YYYY-MM-DD HH:MM:SS.microseconds] [LEVEL] MESSAGE`

### HTTP Access Log File

Configure HTTP access logging with the `access_log_file` option:

```yaml
access_log_file: "access.log"  # Path to access log file
```

Example access log output:
```
127.0.0.1:54321 - - [2025-11-26 07:55:08.073563] "GET / HTTP/1.1" 200 3771 "curl/8.5.0" 0.04ms
127.0.0.1:54321 - - [2025-11-26 07:55:08.082773] "POST /api/test HTTP/1.1" 200 122 "curl/8.5.0" 3.16ms
```

Format: `REMOTE_ADDR - - [YYYY-MM-DD HH:MM:SS.microseconds] "METHOD PATH PROTOCOL" STATUS BYTES "USER_AGENT" DURATIONms`

## Log Rotation

Both application logs and access logs support automatic rotation:

- **Maximum Size**: 10 MB per log file
- **Backup Files**: 5 backup files are kept
- **Rotation Pattern**: `file.log` → `file.log.1` → `file.log.2` → ... → `file.log.5`
- **Error Recovery**: If rotation fails, attempts to reopen backup file

When a log file reaches 10 MB:
1. The oldest backup (`file.log.5`) is deleted
2. All backups are rotated (`file.log.4` → `file.log.5`, etc.)
3. Current log is renamed to `file.log.1`
4. A new `file.log` is created
5. If creation fails, backup file is reopened to prevent log loss

## Timestamp Format

Timestamps use human-readable format with high precision for performance analysis:

```
YYYY-MM-DD HH:MM:SS.microseconds
```

Example: `2025-11-26 07:53:49.729882`

- **Date**: YYYY-MM-DD (ISO 8601 format)
- **Time**: HH:MM:SS.microseconds (24-hour format with 6-digit microsecond precision)
- **Precision**: Microsecond-level precision for accurate performance analysis
- **Timezone**: UTC (server local time)

### Duration in Access Logs

Request durations are shown in milliseconds with 2 decimal places:

- `0.05ms` - 50 microseconds
- `3.37ms` - 3.37 milliseconds
- `125.00ms` - 125 milliseconds

## Security Features

### Log Injection Prevention

The logging system automatically sanitizes user-controlled input to prevent log injection attacks:

- **Path sanitization**: Request paths are sanitized before logging
- **User-Agent sanitization**: User-Agent headers are sanitized
- Newline characters (`\n`, `\r`) are replaced with spaces
- Control characters (ASCII < 32 or 127) are replaced with spaces
- Truncation warnings are logged when fields exceed buffer limits
- This prevents attackers from injecting false log entries or breaking log parsing

Example:
```
Malicious input: "curl/1.0\n[ERROR] Fake log entry"
Sanitized output: "curl/1.0 [ERROR] Fake log entry"
```

**Security measures:**
- 512-byte buffer for path sanitization
- 256-byte buffer for user-agent sanitization  
- 128-byte buffer for IPv6 address formatting
- Truncation detection with warning logs

## Performance Analysis

The access log includes request duration in milliseconds, enabling:

1. **Performance Monitoring**: Track slow requests
2. **Bottleneck Identification**: Find performance issues
3. **Capacity Planning**: Analyze load patterns

### Example Analysis

Find slowest requests:
```bash
# Sort by duration (second to last field)
awk '{print $(NF-1), $0}' access.log | sort -rn | head -10
```

Average request duration:
```bash
awk '{print $(NF-1)}' access.log | sed 's/ms//' | \
  awk '{sum+=$1; n++} END {print sum/n " ms average"}'
```

Requests taking > 100ms:
```bash
awk '{dur=$(NF-1); gsub(/ms/, "", dur); if(dur > 100) print}' access.log
```

## Usage Examples

### Basic Configuration (Console Only)

```yaml
log_level: "info"
# No log_file or access_log_file - logs to console only
```

### Production Configuration

```yaml
log_level: "info"
log_file: "/var/log/zhttpd/application.log"
access_log_file: "/var/log/zhttpd/access.log"
```

### Development Configuration

```yaml
log_level: "debug"
log_file: "debug.log"
access_log_file: "access_debug.log"
```

## Implementation Details

### Thread Safety

The logger uses mutex protection for thread-safe logging across the worker thread pool:

```zig
self.mutex.lock();
defer self.mutex.unlock();
```

### Timestamp Calculation

The logger converts Unix timestamps to human-readable format using efficient date/time calculation:

- Handles leap years correctly
- Uses simple arithmetic for date components
- No external dependencies required
- Optimized for performance

### Access Log as Specialized Logger

The HTTP access logger is built on top of the general-purpose logger:

```zig
pub fn access(...) void {
    // Format access-specific data
    const duration_ms = @as(f64, @floatFromInt(duration_us)) / 1000.0;
    const timestamp_str = formatTimestamp();
    
    // Use general logger with custom format
    self.logWithTimestamp(
        "{s} - - [{s}] \"{s} {s} {s}\" {d} {d} \"{s}\" {d:.2}ms",
        .{ remote_addr, timestamp_str, method, path, protocol, status, bytes_sent, user_agent, duration_ms },
    );
}
```

This design:
- Reuses rotation logic
- Maintains thread safety
- Provides specialized formatting for HTTP logs
- Keeps code DRY (Don't Repeat Yourself)

## Best Practices

1. **Production**: Use `log_level: "info"` with file logging enabled
2. **Development**: Use `log_level: "debug"` for verbose output
3. **Monitoring**: Monitor log file sizes and disk space
4. **Analysis**: Use access logs for performance analysis and troubleshooting
5. **Security**: Keep log files secure with appropriate file permissions
6. **Rotation**: The automatic rotation handles cleanup, no manual intervention needed
7. **Time Format**: Timestamps are in server local time; consider using UTC in production

## Troubleshooting

### Logs Not Appearing in File

1. Check file path is writable
2. Verify log_level is not too restrictive
3. Check file permissions

### Disk Space Issues

1. Adjust rotation settings if needed (modify `DEFAULT_MAX_LOG_SIZE` in logger.zig)
2. Set up external log rotation (logrotate)
3. Archive old logs to separate storage

### Performance Impact

Logging has minimal performance impact:
- Asynchronous writes to disk
- Efficient timestamp generation
- Minimal string formatting
- Arena allocation for temporary buffers

Access log timing overhead: < 0.1 milliseconds per request

# zhttpd API Reference

This document provides comprehensive API documentation for zhttpd, covering both internal (Zig) and external (HTTP/Lua) interfaces.

**Version:** 0.4.0
**Last Updated:** 2025-11-29

---

## Table of Contents

1. [HTTP Endpoints](#http-endpoints)
2. [Lua API](#lua-api)
3. [Configuration Reference](#configuration-reference)
4. [Internal Zig API](#internal-zig-api)

---

## HTTP Endpoints

### Static Files

**Endpoint:** `GET /*`

Serves static files from the configured `static_dir`.

**Features:**
- MIME type detection
- ETag caching
- Cache-Control headers
- Path traversal protection

**Response Headers:**
```
Content-Type: <detected MIME type>
ETag: W/"<size>-<mtime>"
Cache-Control: public, max-age=3600
```

**Status Codes:**
| Code | Description |
|------|-------------|
| 200 | File served successfully |
| 304 | Not Modified (ETag match) |
| 400 | Bad Request (path traversal attempt) |
| 404 | File not found |
| 413 | File too large |

---

### REST API (Lua)

**Endpoint:** `GET|POST /api/*`

Routes requests to Lua scripts based on path.

**Path Mapping:**
| URL | Script |
|-----|--------|
| `/api/users` | `users.lua` |
| `/api/users/123` | `users.lua` |
| `/api/todo` | `todo.lua` |

**Request Headers:**
- `Content-Type` - Request body format
- `Authorization` - Auth token (if auth enabled)

**Response:**
- Content-Type: `application/json`
- Body: JSON output from Lua handler

---

### WebSocket

**Endpoint:** `WS /ws`

General WebSocket endpoint with Lua message handling.

**Connection Flow:**
1. Client connects via WebSocket upgrade
2. Server loads `websocket.lua` handler
3. Messages routed to Lua for processing
4. Responses sent back to client

**Lua Handler:**
```lua
-- examples/lua/websocket.lua
function handle_request(request)
    local event_type = request.type  -- "connect", "message", "disconnect"
    local data = request.data
    return { type = "response", data = "Hello!" }
end
return { handle = handle_request }
```

---

### Server-Sent Events (SSE)

**Endpoint:** `GET /events`

Server-Sent Events stream for real-time updates.

**Response Headers:**
```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

**Event Format:**
```
event: message
data: {"timestamp": 1234567890}

event: heartbeat
data: ping

```

---

### Health Check

**Endpoint:** `GET /health`

Returns server health status.

**Response:**
```json
{
  "status": "healthy",
  "uptime": 3600,
  "components": {
    "lua": { "status": "healthy" },
    "database": { "status": "healthy" }
  }
}
```

**Status Codes:**
| Code | Description |
|------|-------------|
| 200 | All components healthy |
| 503 | One or more components unhealthy |

---

### Prometheus Metrics

**Endpoint:** `GET /metrics`

Returns metrics in Prometheus text exposition format.

**Metrics Exported:**
```
# HELP zhttpd_requests_total Total HTTP requests
# TYPE zhttpd_requests_total counter
zhttpd_requests_total{status="200"} 12345

# HELP zhttpd_request_duration_seconds Request duration histogram
# TYPE zhttpd_request_duration_seconds histogram
zhttpd_request_duration_seconds_bucket{le="0.01"} 1000

# HELP zhttpd_response_size_bytes Response size histogram
# TYPE zhttpd_response_size_bytes histogram
zhttpd_response_size_bytes_bucket{le="1024"} 5000
```

---

## Lua API

### Handler Signature

All Lua scripts must export a table with a `handle` function:

```lua
function handle(request, response, context)
    -- Process request
    return { status = "success" }
end

return { handle = handle }
```

---

### Request Object

#### `request:method()`
Returns the HTTP method as a string.

```lua
local method = request:method()  -- "GET", "POST", "PUT", "DELETE"
```

#### `request:path()`
Returns the request path without query string.

```lua
local path = request:path()  -- "/api/users"
```

#### `request:url()`
Returns the full URL including query string.

```lua
local url = request:url()  -- "/api/users?page=1&limit=10"
```

#### `request:header(name)`
Returns a specific header value, or `nil` if not found.

```lua
local content_type = request:header("content-type")
local auth = request:header("authorization")
```

#### `request:headers()`
Returns all headers as a Lua table.

```lua
local headers = request:headers()
for name, value in pairs(headers) do
    print(name, value)
end
```

#### `request:query(name)`
Returns a query parameter value, or `nil` if not found.

```lua
local page = request:query("page") or "1"
local limit = request:query("limit") or "10"
```

#### `request:query_all()`
Returns all query parameters as a Lua table.

```lua
local params = request:query_all()
-- params.page, params.limit, etc.
```

#### `request:body()`
Returns the request body. For JSON content, automatically parsed to table.

```lua
local data = request:body()
if type(data) == "table" then
    local username = data.username
end
```

#### `request:body_raw()`
Always returns the body as a raw string.

```lua
local raw = request:body_raw()
```

---

### Response Object

#### `response:status(code)`
Sets the HTTP status code.

```lua
response:status(200)  -- OK
response:status(201)  -- Created
response:status(400)  -- Bad Request
response:status(404)  -- Not Found
response:status(500)  -- Internal Server Error
```

#### `response:header(name, value)`
Sets a response header.

```lua
response:header("X-Custom-Header", "custom-value")
response:header("Cache-Control", "no-cache")
```

#### `response:content_type(type)`
Sets the Content-Type header.

```lua
response:content_type("application/json")
response:content_type("text/html")
response:content_type("text/plain")
```

#### `response:body(content)`
Sets the response body directly.

```lua
response:content_type("text/html")
response:body("<html><body>Hello!</body></html>")
-- Return nil to prevent JSON serialization from overwriting
```

---

### Context Object

The `context` parameter is a Lua table for per-request data storage.

```lua
function handle(request, response, context)
    context.start_time = os.time()
    context.user_id = nil

    -- Use later in the handler
    local elapsed = os.time() - context.start_time
end
```

---

### Database API

Access databases via the context:

#### `context:db([name])`
Get a database connection. Omit name for default datasource.

```lua
local db = context:db()           -- Default datasource
local users_db = context:db("users_db")  -- Named datasource
```

#### `db:query(sql, ...)`
Execute a SELECT query and return results.

```lua
local result, err = db:query("SELECT * FROM users WHERE id = ?", 1)
if not err then
    for _, row in ipairs(result) do
        print(row.name, row.email)
    end
end
```

#### `db:exec(sql, ...)`
Execute INSERT/UPDATE/DELETE and return affected rows.

```lua
local affected, err = db:exec(
    "INSERT INTO users (name, email) VALUES (?, ?)",
    "John", "john@example.com"
)
```

#### `db:begin()`, `db:commit()`, `db:rollback()`
Transaction support.

```lua
db:begin()
db:exec("UPDATE accounts SET balance = balance - 100 WHERE id = ?", 1)
db:exec("UPDATE accounts SET balance = balance + 100 WHERE id = ?", 2)
db:commit()
```

#### `db:status()`
Get database connection status.

```lua
local status = db:status()
print(status.connected)   -- true/false
print(status.uri)         -- Connection URI
```

---

### JSON Module (json)

Built-in JSON encoding/decoding.

#### `json.encode(value)`
Encode Lua value to JSON string.

```lua
local data = { name = "John", age = 30 }
local json_str = json.encode(data)
-- '{"name":"John","age":30}'
```

#### `json.decode(json)`
Decode JSON string to Lua value.

```lua
local data = json.decode('{"name":"John","age":30}')
print(data.name)  -- "John"
```

---

## Configuration Reference

### Complete Configuration Options

```yaml
# Server Configuration
host: "0.0.0.0"              # Bind address
port: 8080                    # Listen port
thread_pool_size: 4          # Worker threads
max_connections: 512         # Max concurrent connections
request_buffer_size: 65536   # Request buffer (bytes)
timeout_seconds: 30          # Request timeout

# Static Files
static_dir: "./examples/static"
max_cache_file_size: 1048576  # Max file size to cache (1MB)
enable_etag: true             # ETag caching

# Dynamic Content
enable_lua: true
lua_scripts_dir: "./examples/lua"
lua_sandbox_enabled: true     # Enable sandbox
lua_max_instructions: 100000  # Instruction limit (0 = unlimited)
reload: "auto"                # Cache mode: never, auto, force


# WebSocket & SSE
enable_websocket: false
enable_sse: false

# Security
security_headers: true
enable_rate_limit: false
rate_limit_requests: 100
rate_limit_window: 60
enable_cors: false
cors_origins: "*"
cors_methods: "GET, POST, PUT, DELETE, OPTIONS"
cors_headers: "Content-Type, Authorization"
enable_auth: false
auth_script: "auth"
auth_protected_paths: "/api/*"
auth_public_paths: "/api/login, /api/register"
enable_ip_blacklist: false
ip_blacklist: ""
ip_whitelist: ""

# Observability
enable_metrics: true
enable_health_check: true
enable_request_id: true
log_level: "info"             # debug, info, warn, error
log_format: "text"            # text, json
log_file: null                # null = stdout
access_log_file: null

# Database
enable_db: false
db_uri: ""
db_pool_size: 5
data_sources: []              # Named datasources
```

### Handler Mappings

Configure URL-to-handler routing:

```yaml
# Sequence format (preserves order)
handlers:
  - pattern: /health
    handler: Handler.HealthCheckHandler
  - pattern: /metrics
    handler: Handler.MetricsHandler
  - pattern: /ws
    handler: Handler.WebSocketHandler
  - pattern: /api/*
    handler: Handler.LuaHandler
  - pattern: /events
    handler: Handler.SSEHandler
  - pattern: /*
    handler: Handler.StaticFileHandler
```

### Available Handlers

| Handler | Description |
|---------|-------------|
| `Handler.StaticFileHandler` | Serve static files |
| `Handler.LuaHandler` | Execute Lua scripts |
| `Handler.WebSocketHandler` | WebSocket connections |
| `Handler.SSEHandler` | Server-Sent Events |
| `Handler.HealthCheckHandler` | Health status |
| `Handler.MetricsHandler` | Prometheus metrics |

---

## Internal Zig API

### AppContext

Application context holding shared state for all request handlers.

```zig
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    file_cache: *FileCache,
    lua_handler: ?LuaHandler,
    logger: Logger,
    access_logger: ?Logger,
    rate_limiter: ?*RateLimiter,
    cors_middleware: ?CorsMiddleware,
    auth_middleware: ?AuthMiddleware,
    metrics: ?*Metrics,
    start_time: i64,
    ip_access_control: ?*IpAccessControl,
    db_manager: ?*DbManager,

    pub fn init(allocator: std.mem.Allocator, config: Config) !AppContext;
    pub fn deinit(self: *AppContext) void;
};
```

### HttpzServer

Server wrapper with route configuration.

```zig
pub const HttpzServer = struct {
    pub fn init(allocator: std.mem.Allocator, config: Config) !HttpzServer;
    pub fn deinit(self: *HttpzServer) void;
    pub fn setupRoutes(self: *HttpzServer) !void;
    pub fn listen(self: *HttpzServer) !void;
    pub fn stop(self: *HttpzServer) void;
};
```

### FileCache

Thread-safe file cache with multiple reload strategies.

```zig
pub const FileCache = struct {
    pub fn init(allocator: std.mem.Allocator, reload_mode: ReloadMode, max_size: usize) FileCache;
    pub fn deinit(self: *FileCache) void;
    pub fn loadFile(self: *FileCache, path: []const u8) ![]const u8;
    pub fn generateETag(allocator: std.mem.Allocator, size: u64, mtime: i128) ![]const u8;
    pub fn clear(self: *FileCache) void;
    pub fn count(self: *FileCache) usize;
};
```

### LuaHandler

Thread-safe Lua script executor.

```zig
pub const LuaHandler = struct {
    pub fn init(allocator: std.mem.Allocator, scripts_dir: []const u8, file_cache: *FileCache) !LuaHandler;
    pub fn initWithConfig(allocator: std.mem.Allocator, scripts_dir: []const u8, file_cache: *FileCache, config: SandboxConfig) !LuaHandler;
    pub fn deinit(self: *LuaHandler) void;
    pub fn executeScriptWithContext(self: *LuaHandler, script_name: []const u8, req: *httpz.Request, res: *httpz.Response) ![]const u8;
    pub fn loadScript(self: *LuaHandler, script_name: []const u8) ![]const u8;
    pub fn clearBytecodeCache(self: *LuaHandler) void;
};
```

### RateLimiter

Token bucket rate limiter with per-IP tracking.

```zig
pub const RateLimiter = struct {
    pub fn init(allocator: std.mem.Allocator, config: RateLimiterConfig) RateLimiter;
    pub fn deinit(self: *RateLimiter) void;
    pub fn checkRequest(self: *RateLimiter, ip: ?[]const u8) bool;
    pub fn getRemainingTokens(self: *RateLimiter, ip: ?[]const u8) u32;
};
```

### Logger

Multi-level logging with optional file output.

```zig
pub const Logger = struct {
    pub fn init(allocator: std.mem.Allocator, level: LogLevel, file: ?[]const u8) !Logger;
    pub fn initWithFormat(allocator: std.mem.Allocator, level: LogLevel, file: ?[]const u8, format: LogFormat) !Logger;
    pub fn deinit(self: *Logger) void;
    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void;
    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void;
    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void;
    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void;
    pub fn access(self: *Logger, ip: []const u8, method: []const u8, path: []const u8, protocol: []const u8, status: u16, size: usize, user_agent: []const u8, duration: i64) void;
};
```

---

## Error Handling

### HTTP Status Codes

| Code | Name | When Used |
|------|------|-----------|
| 200 | OK | Request successful |
| 201 | Created | Resource created |
| 204 | No Content | CORS preflight |
| 304 | Not Modified | ETag cache hit |
| 400 | Bad Request | Invalid input |
| 401 | Unauthorized | Missing auth |
| 403 | Forbidden | IP blocked / Access denied |
| 404 | Not Found | Resource not found |
| 405 | Method Not Allowed | Invalid HTTP method |
| 413 | Payload Too Large | Body exceeds limit |
| 429 | Too Many Requests | Rate limited |
| 500 | Internal Server Error | Server error |
| 503 | Service Unavailable | Handler not initialized |

### Lua Error Responses

```json
{
  "status": "error",
  "message": "Script execution failed"
}
```


```json
{
  "data": null,
  "errors": [
    {
      "message": "Field 'unknown' not found",
      "locations": [{"line": 1, "column": 3}]
    }
  ]
}
```

---

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
- [SECURITY.md](SECURITY.md) - Security features
- [LUA_PROGRAMMING_GUIDE.md](LUA_PROGRAMMING_GUIDE.md) - Lua scripting guide
- [HTTP_REQUEST_HANDLING.md](HTTP_REQUEST_HANDLING.md) - Request processing flow
- [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md) - Performance optimization

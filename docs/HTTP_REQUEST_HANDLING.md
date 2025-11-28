# HTTP Request Handling Design Guide

This document provides a comprehensive design guide for HTTP request handling in zhttpd, inspired by Apache httpd, Nginx, and OpenResty architectures.

## Table of Contents

- [Overview](#overview)
- [Connection Lifecycle](#connection-lifecycle)
- [Request Processing Phases](#request-processing-phases)
- [Handler Chain Architecture](#handler-chain-architecture)
- [Security Considerations](#security-considerations)
- [Extension Points](#extension-points)
- [Implementation Status](#implementation-status)

## Overview

zhttpd follows an event-driven, modular architecture that processes HTTP requests through a well-defined pipeline. The design prioritizes:

1. **Performance** - Efficient memory management with arena allocators
2. **Security** - Defense-in-depth with multiple security layers
3. **Extensibility** - Clean handler chain for easy feature additions
4. **Maintainability** - Clear separation of concerns

### Core Design Principles

```
┌─────────────────────────────────────────────────────────────┐
│                    Design Philosophy                         │
├─────────────────────────────────────────────────────────────┤
│ 1. Explicit over implicit - No hidden behavior              │
│ 2. Fail fast - Validate early, respond immediately          │
│ 3. Resource safety - Arena allocators for request lifecycle │
│ 4. Thread safety - Mutex protection for shared state        │
│ 5. Composability - Modular middleware chain                 │
└─────────────────────────────────────────────────────────────┘
```

## Connection Lifecycle

### Phase 1: Server Initialization

**Core Tasks:**
- Load and parse configuration (JSON/YAML)
- Initialize memory allocators and resource pools
- Set up worker thread pool
- Initialize logging and metrics systems
- Load handlers (Lua, GraphQL)

**zhttpd Implementation:**

```zig
// In main.zig - Server initialization
var server = try httpz_handlers.HttpzServer.init(allocator, config);

// In AppContext.init() - Resource initialization with proper error handling
pub fn init(allocator: std.mem.Allocator, config: Config) !AppContext {
    // Initialize logger with format from config
    var logger = try Logger.initWithFormat(allocator, log_level, config.log_file, log_format);
    errdefer logger.deinit();
    
    // Initialize file cache (shared across all handlers)
    const file_cache = try allocator.create(FileCache);
    errdefer allocator.destroy(file_cache);
    file_cache.* = FileCache.init(allocator, config.reload, config.max_cache_file_size);
    errdefer file_cache.deinit();
    
    // Initialize context with handlers and middleware
    var ctx = AppContext{
        .allocator = allocator,
        .config = config,
        .file_cache = file_cache,
        .logger = logger,
        .start_time = std.time.timestamp(),
    };
    
    // Initialize Lua handler if enabled
    if (config.enable_lua) {
        ctx.lua_handler = try LuaHandler.initWithConfig(allocator, config.lua_scripts_dir, ...);
        errdefer if (ctx.lua_handler) |*lua| lua.deinit();
    }
    
    // Initialize middleware (rate limiter, CORS, auth)
    // Initialize observability (metrics, health)
    
    return ctx;
}
```

### Phase 2: Connection Establishment

**Core Tasks:**
- Accept TCP connection via httpz worker pool
- Assign worker thread for connection
- Create per-request arena allocator
- Parse HTTP request

**Architecture:**

```
Client Request
      │
      ▼
┌─────────────────┐
│  httpz.Server   │  ◄─── Connection pool, worker threads
│  (listen/accept)│
└─────────────────┘
      │
      ▼
┌─────────────────┐
│  Worker Thread  │  ◄─── Per-request arena allocator
│  (assigned)     │
└─────────────────┘
```

### Phase 3: Request Processing

See [Request Processing Phases](#request-processing-phases) for detailed flow.

### Phase 4: Response Generation

**Core Tasks:**
- Generate response body (static file, dynamic content)
- Add security headers
- Set appropriate content type
- Handle compression (future)

### Phase 5: Logging and Cleanup

**Core Tasks:**
- Record access log entry
- Update metrics (request count, latency, size)
- Release arena allocator (automatic cleanup)
- Connection handling (keep-alive vs close)

## Request Processing Phases

### Complete Request Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Request Processing Flow                       │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 1: Request ID Generation                                       │
│ - Generate or propagate X-Request-ID                                 │
│ - Enable request tracing across components                           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 2: IP Access Control                                           │
│ - Check IP against blacklist/whitelist                               │
│ - CIDR range support                                                 │
│ - Return 403 if blocked                                              │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 3: Rate Limiting                                               │
│ - Token bucket algorithm per IP                                      │
│ - Whitelisted IPs bypass rate limiting                               │
│ - Return 429 with Retry-After if exceeded                            │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 4: CORS Handling                                               │
│ - Process preflight OPTIONS requests                                 │
│ - Add Access-Control-* headers                                       │
│ - Return 204 for preflight                                           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 5: Authentication                                              │
│ - Check if path requires authentication                              │
│ - Validate token (via Lua script)                                    │
│ - Return 401/403 if failed                                           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 6: Route Matching                                              │
│ - Match URL path to registered handlers                              │
│ - Priority: /health > /metrics > /ws > /graphql > /api/* > /*       │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 7: Handler Execution                                           │
│ - Execute matched handler                                            │
│ - Static files: file cache with ETag support                         │
│ - Lua API: sandbox execution with resource limits                    │
│ - GraphQL: query parsing and Lua resolver delegation                 │
│ - WebSocket: upgrade and message handling                            │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 8: Security Headers                                            │
│ - Add CSP, HSTS, X-Frame-Options, etc.                               │
│ - Configurable per response type                                     │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 9: Access Logging & Metrics                                    │
│ - Log: IP, method, path, status, size, duration                      │
│ - Metrics: request count, latency histogram, response size           │
└─────────────────────────────────────────────────────────────────────┘
```

### Phase Implementation Details

#### Phase 1-5: Middleware Chain

```zig
// In httpz_handlers.zig
fn applyMiddleware(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) bool {
    // Phase 2: IP Access Control
    if (ctx.ip_access_control) |ip_control| {
        switch (ip_control.checkAccess(ip)) {
            .blocked => { res.status = 403; return false; },
            .whitelisted => is_whitelisted = true,
            .allowed => {},
        }
    }

    // Phase 3: Rate Limiting
    if (ctx.rate_limiter) |rate_limiter| {
        if (!is_whitelisted and !rate_limiter.checkRequest(client_ip)) {
            res.status = 429;
            return false;
        }
    }

    // Phase 4: CORS Handling
    if (ctx.cors_middleware) |*cors| {
        if (req.method == .OPTIONS) {
            res.status = 204;
            return false;
        }
    }

    // Phase 5: Authentication
    if (ctx.auth_middleware) |*auth| {
        if (auth.requiresAuth(req.url.path)) {
            // Validate token via Lua
        }
    }

    return true;
}
```

#### Phase 6: Route Matching

Routes are now configured via the `handlers` section in the YAML configuration file.
This allows for flexible route-to-handler mapping without code changes.

```yaml
# Example configuration in zhttpd.yaml
handlers:
  /health: Handler.HealthCheckHandler
  /metrics: Handler.MetricsHandler
  /ws: Handler.WebSocketHandler
  /graphql/playground: Handler.GraphQLPlaygroundHandler
  /graphql/ws: Handler.WebSocketHandler
  /graphql: Handler.GraphQLHandler
  /api/*: Handler.LuaHandler
  /events: Handler.SSEHandler
  /*: Handler.StaticFileHandler
```

```zig
// In HttpzServer.setupRoutes()
pub fn setupRoutes(self: *HttpzServer) !void {
    const router = try self.server.router(.{});

    // Register routes based on handler configuration
    // Routes are processed in order, so more specific routes should come first
    for (self.context.config.handlers) |mapping| {
        self.registerHandler(router, mapping);
    }
}

fn registerHandler(self: *HttpzServer, router: anytype, mapping: HandlerMapping) void {
    // Match handler name to actual handler function
    if (std.mem.eql(u8, mapping.handler, "Handler.StaticFileHandler")) {
        router.get(mapping.pattern, serveStatic, .{});
    } else if (std.mem.eql(u8, mapping.handler, "Handler.LuaHandler")) {
        router.get(mapping.pattern, luaApi, .{});
        router.post(mapping.pattern, luaApi, .{});
    }
    // ... etc
}
```

## Handler Chain Architecture

### Handler Interface Pattern

Each handler follows a consistent pattern:

```zig
fn handler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // 1. Start timing
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    // 2. Add request ID
    addRequestIdHeader(ctx, req, res);

    // 3. Apply middleware
    if (!applyMiddleware(ctx, req, res)) return;

    // 4. Handler-specific logic
    // ...

    // 5. Add security headers (if applicable)
    if (ctx.config.security_headers) {
        addSecurityHeaders(res);
    }
}
```

### Handler Types

| Handler | Path | Purpose | Features |
|---------|------|---------|----------|
| healthHandler | /health | Health check | Component status, uptime |
| metricsHandler | /metrics | Prometheus metrics | Request counts, latencies |
| websocketHandler | /ws | WebSocket upgrade | Lua message handling |
| graphqlGet/Post | /graphql | GraphQL API | Query parsing, Lua resolvers |
| graphqlPlayground | /graphql/playground | GraphQL IDE | Interactive testing |
| luaApi | /api/* | REST API | Lua script execution |
| serveStatic | /* | Static files | ETag, caching |
| sseHandler | /events | Server-Sent Events | Real-time streaming |

## Security Considerations

### Input Validation

```zig
// Path traversal prevention
if (std.mem.indexOf(u8, clean_path, "..") != null) {
    res.status = 400;
    res.body = "Bad Request";
    return;
}

// Log field sanitization
fn sanitizeLogField(buf: []u8, input: []const u8) []const u8 {
    // Remove newlines and control characters
}
```

### Security Headers

Default security headers applied to responses:

| Header | Value | Purpose |
|--------|-------|---------|
| Content-Security-Policy | default-src 'self'... | XSS prevention |
| X-Frame-Options | SAMEORIGIN | Clickjacking prevention |
| X-Content-Type-Options | nosniff | MIME sniffing prevention |
| X-XSS-Protection | 1; mode=block | XSS filter |
| Strict-Transport-Security | max-age=31536000 | HTTPS enforcement |
| Referrer-Policy | strict-origin-when-cross-origin | Referrer control |
| Permissions-Policy | geolocation=()... | Feature control |

### Request Size Limits

```zig
// Global limit in config
max_body_size: 10 * 1024 * 1024,  // 10MB

// Per-file limit
const MAX_FILE_SIZE = 10 * 1024 * 1024;

// Route-specific limits (via RouteSizeLimiter)
const limits = [_]RouteSizeLimit{
    .{ .path_pattern = "/api/upload", .max_body_size = 50 * 1024 * 1024 },
    .{ .path_pattern = "/graphql", .max_body_size = 100 * 1024 },
};
```

### Lua Sandboxing

```zig
// Sandbox configuration
const sandbox_config = lua_mod.SandboxConfig{
    .max_instructions = config.lua_max_instructions,  // Default: 100,000
    .enable_sandbox = config.lua_sandbox_enabled,     // Default: true
};

// Disabled dangerous functions:
// - io module
// - os.execute
// - debug module
```

## Extension Points

### Adding a New Handler

1. Create handler module in `src/handlers/` (e.g., `my_handler.zig`):

```zig
//! My Custom Handler
//!
//! Description of what this handler does.

const std = @import("std");
const httpz = @import("httpz");
const AppContext = @import("httpz_handlers.zig").AppContext;

/// Handle custom requests
pub fn handle(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Your handler logic here
    res.body = "Hello from my handler!";
    res.content_type = httpz.ContentType.TEXT;
}
```

2. Import and register in `httpz_handlers.zig`:

```zig
// Add import at the top with other handler imports
const my_handler = @import("my_handler.zig");

// Create wrapper function for the dispatcher
fn myHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const start_time = std.time.microTimestamp();
    defer {
        const duration = std.time.microTimestamp() - start_time;
        logAccess(ctx, req, res, duration);
    }

    addRequestIdHeader(ctx, req, res);
    if (!applyMiddleware(ctx, req, res)) return;

    // Delegate to the modular handler
    try my_handler.handle(ctx, req, res);
}

// Add to registerHandler function
} else if (std.mem.eql(u8, handler_name, "Handler.MyHandler")) {
    router.get(pattern, myHandler, .{});
}
```

3. Configure in YAML:

```yaml
handlers:
  /my-endpoint: Handler.MyHandler
  /*: Handler.StaticFileHandler
```

### Adding New Middleware

1. Create middleware in `middleware/`:

```zig
pub const MyMiddleware = struct {
    config: MyConfig,

    pub fn init(config: MyConfig) MyMiddleware {
        return .{ .config = config };
    }

    /// Check if request should proceed
    /// Returns true to continue, false to block
    pub fn check(self: *MyMiddleware, req: *Request, res: *Response) bool {
        if (self.shouldBlock(req)) {
            res.status = 403;
            res.body = "Forbidden";
            return false;
        }
        return true;
    }
    
    pub fn deinit(self: *MyMiddleware) void {
        // Clean up resources
    }
};
```

2. Add to `AppContext`:

**Recommended: Middleware Registry Pattern (Scalable)**

For servers with many middleware components, use a registry approach:

```zig
pub const MiddlewareRegistry = struct {
    items: std.ArrayList(MiddlewareEntry),
    
    pub const MiddlewareEntry = struct {
        name: []const u8,
        priority: u32,  // Lower = earlier execution
        check_fn: *const fn(req: *Request, res: *Response) bool,
    };
    
    pub fn register(self: *MiddlewareRegistry, entry: MiddlewareEntry) !void {
        try self.items.append(entry);
        // Sort by priority
    }
    
    pub fn apply(self: *MiddlewareRegistry, req: *Request, res: *Response) bool {
        for (self.items.items) |entry| {
            if (!entry.check_fn(req, res)) return false;
        }
        return true;
    }
};
```

**Alternative: Direct Field Approach (Simple, but limited scalability)**

For a small number of middleware, you can add optional fields directly:

```zig
pub const AppContext = struct {
    // ...existing fields...
    
    // Note: This approach is simpler but doesn't scale well beyond a few
    // middleware components. Use the registry pattern for many middleware.
    my_middleware: ?MyMiddleware = null,
};
```

3. Initialize in `AppContext.init()` and add to `applyMiddleware()`.

### Adding Lua Functions

Extend `lua/lua.zig` to expose Zig functions to Lua:

```zig
fn myZigFunction(lua: *ziglua.Lua) i32 {
    // Get arguments from Lua stack
    const arg = lua.toString(1) orelse "";
    
    // Do something
    const result = processData(arg);
    
    // Push result to Lua stack
    lua.pushString(result);
    return 1; // Number of return values
}

// Register in ThreadLocalLua.init()
lua.pushFunction(ziglua.wrap(myZigFunction));
lua.setGlobal("myFunction");
```

## Implementation Status

### Completed Features (✅)

| Category | Feature | Implementation |
|----------|---------|----------------|
| **Initialization** | Configuration (JSON/YAML) | `config/config.zig` |
| | Thread pool | httpz worker model |
| | Resource pools | Arena allocators |
| **Security** | Security headers | `security/security.zig` |
| | IP blacklist/whitelist | `middleware/rate_limiter.zig` |
| | Rate limiting | Token bucket algorithm |
| | Path traversal prevention | Handler validation |
| | Lua sandboxing | Instruction limits, disabled functions |
| | CORS | `middleware/cors.zig` |
| | Authentication (Lua) | `middleware/auth.zig` |
| **Handlers** | Static files | ETag, caching |
| | Lua API | Script execution with context |
| | GraphQL | Query parsing, Lua resolvers |
| | WebSocket | Lua message handling |
| | SSE | Event streaming |
| | Health check | Component status |
| | Metrics | Prometheus format |
| **Observability** | Access logging | Structured logs |
| | Request ID | X-Request-ID propagation |
| | Prometheus metrics | Request counts, latencies |

### Future Enhancements

| Category | Feature | Priority |
|----------|---------|----------|
| **Performance** | Response compression (gzip) | Medium |
| | HTTP/2 support | Low (depends on httpz) |
| | Zero-copy file serving | Low |
| **Security** | Request signing | Low |
| | CSP nonce generation | Low |
| **Observability** | OpenTelemetry tracing | Low |
| | Log aggregation | Low |

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture overview
- [SECURITY.md](SECURITY.md) - Security features
- [OWASP_COMPLIANCE.md](OWASP_COMPLIANCE.md) - Security compliance
- [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md) - Optimization guide
- [LOGGING.md](LOGGING.md) - Logging configuration
- [OBSERVABILITY.md](OBSERVABILITY.md) - Metrics and monitoring

---

**Last Updated:** 2025-11-28
**Status:** Active Documentation

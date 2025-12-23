# zhttpd System Architecture

This document provides a comprehensive overview of the zhttpd web server architecture, designed to help developers understand, maintain, and extend the codebase.

## Table of Contents

- [Overview](#overview)
- [Architecture Diagram](#architecture-diagram)
- [Module Structure](#module-structure)
- [Core Components](#core-components)
- [Request Processing Flow](#request-processing-flow)
- [Extension Points](#extension-points)
- [Design Principles](#design-principles)

## Overview

zhttpd is a high-performance, modular HTTP web server written in Zig. It follows the Zig philosophy of simplicity, performance, and explicit control flow.

### Key Design Goals

1. **High Performance** - Leverages Zig's low-level control and zero-cost abstractions
2. **Modularity** - Clean separation of concerns with well-defined interfaces
3. **Extensibility** - Plugin architecture through Lua scripting
4. **Security** - Defense-in-depth with multiple security layers
5. **Observability** - Built-in metrics, health checks, and structured logging

### Technology Stack

| Component | Library | Purpose |
|-----------|---------|---------|
| HTTP Server | [http.zig](https://github.com/karlseguin/http.zig) | High-performance HTTP/1.1 implementation |
| Scripting | [ziglua](https://github.com/natecraddock/ziglua) | Lua 5.4 integration for dynamic content |

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Client Requests                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Reverse Proxy (TLS Termination)                       │
│                           nginx / Caddy / haproxy                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              httpz.Server                                     │
│                         (Connection & Thread Pool)                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Middleware Chain                                    │
│  ┌───────────────┐  ┌───────────────┐  ┌─────────────┐  ┌──────────────┐    │
│  │ IP Access     │─▶│ Rate Limiter  │─▶│ CORS        │─▶│ Auth         │    │
│  │ Control       │  │               │  │ Handler     │  │ Middleware   │    │
│  └───────────────┘  └───────────────┘  └─────────────┘  └──────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Router                                           │
│                                                                               │
│   /health    ──────▶  Health Check Handler                                   │
│   /metrics   ──────▶  Metrics Handler (Prometheus)                           │
│   /ws        ──────▶  WebSocket Handler                                      │
│   /api/*     ──────▶  Lua API Handler                                        │
│   /*         ──────▶  Static File Handler                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                ▼                     ▼                     ▼
┌───────────────────────┐ ┌───────────────────────┐ ┌───────────────────────┐
│    Static Files       │ │    Lua Engine         │ │    WebSocket          │
│    (FileCache)        │ │    (Thread-local VM)  │ │    Handler            │
└───────────────────────┘ └───────────────────────┘ └───────────────────────┘
```

## Module Structure

```
src/
├── main.zig              # Application entry point
├── config/
│   └── config.zig        # Configuration loading (JSON/YAML)
├── handlers/
│   ├── httpz_handlers.zig # HTTP request handlers
│   └── websocket.zig      # WebSocket handler
├── middleware/
│   ├── middleware.zig     # Middleware module exports
│   ├── rate_limiter.zig   # Rate limiting & IP access control
│   ├── cors.zig           # CORS handling
│   └── auth.zig           # Authentication middleware
├── lua/
│   └── lua.zig            # Lua integration & sandboxing
├── cache/
│   └── file_cache.zig     # File caching with reload modes
├── security/
│   └── security.zig       # Security headers & CSP generation
├── logger/
│   └── logger.zig         # Structured logging
└── observability/
    ├── observability.zig  # Module exports
    ├── metrics.zig        # Prometheus metrics
    ├── health.zig         # Health checks
    └── request_id.zig     # Request ID propagation
```

## Core Components

### 1. Configuration (`config/config.zig`)

Manages server configuration with support for:

- **JSON format** - Full-featured configuration
- **YAML format** - Human-friendly configuration
- **Default values** - Sensible defaults for all options
- **Hot-reload** - File cache reload modes (never, auto, force)

```zig
pub const Config = struct {
    host: []const u8,
    port: u16,
    static_dir: []const u8,
    lua_scripts_dir: []const u8,
    // ... 40+ configuration options
};
```

### 2. HTTP Handlers (`handlers/httpz_handlers.zig`)

The main request processing module containing:

- **AppContext** - Shared application state (handlers, caches, middleware)
- **HttpzServer** - Server wrapper with route setup

### 3. Middleware Chain (`middleware/`)

Composable middleware for request processing:

| Middleware | File | Purpose |
|------------|------|---------|
| IP Access Control | `rate_limiter.zig` | Block/allow by IP/CIDR |
| Rate Limiter | `rate_limiter.zig` | Token bucket rate limiting |
| CORS | `cors.zig` | Cross-origin resource sharing |
| Authentication | `auth.zig` | Token validation (Lua-delegated) |

### 4. Lua Integration (`lua/lua.zig`)

Thread-safe Lua scripting engine:

- **Thread-local VMs** - Each worker thread has dedicated Lua state
- **Sandboxing** - Disabled dangerous functions (io, os.execute, debug)
- **Instruction limits** - Prevent infinite loops
- **Script caching** - Via shared FileCache

### 5. File Cache (`cache/file_cache.zig`)

High-performance file caching:

```zig
pub const ReloadMode = enum {
    never,  // Cache forever (production)
    auto,   // Check mtime (development)
    force,  // Always read (debugging)
};
```

### 6. Security (`security/security.zig`)

Comprehensive security features:

- **Security Headers** - CSP, HSTS, X-Frame-Options, etc.
- **CSP Generator** - Programmatic Content Security Policy
- **Route Size Limits** - Per-path body size limits
- **Path Traversal Prevention** - Built into handlers

### 7. Observability (`observability/`)

Production-ready observability:

- **Prometheus Metrics** - Request counts, latencies, sizes
- **Health Checks** - Service status with JSON response
- **Request ID Propagation** - Distributed tracing support
- **Structured Logging** - JSON or text format

## Request Processing Flow

```
1. Connection Accepted
   │
   ▼
2. httpz Worker Thread Assigned
   │
   ▼
3. Request Parsed
   │
   ▼
4. Middleware Chain (in order):
   ├─ IP Access Control → 403 if blocked
   ├─ Rate Limiter → 429 if exceeded
   ├─ CORS Handler → 204 for preflight
   └─ Auth Middleware → 401/403 if failed
   │
   ▼
5. Route Matched → Handler Selected
   │
   ├─▶ /health → Health Check (no metrics)
   ├─▶ /metrics → Prometheus Export (no metrics)
   ├─▶ /ws → WebSocket Upgrade
   ├─▶ /api/* → Lua Script Execution
   └─▶ /* → Static File Serving
   │
   ▼
6. Handler Execution
   │
   ▼
7. Security Headers Added (if enabled)
   │
   ▼
8. Access Logging & Metrics Recording
   │
   ▼
9. Response Sent
```

## Extension Points

### Adding a New Handler

1. Create handler function in `httpz_handlers.zig`:
```zig
fn myHandler(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Apply middleware
    if (!applyMiddleware(ctx, req, res)) return;

    // Your logic here
    res.body = "Hello!";
}
```

2. Register route in `setupRoutes()`:
```zig
router.get("/my-path", myHandler, .{});
```

### Adding a New Middleware

1. Create middleware in `middleware/`:
```zig
pub const MyMiddleware = struct {
    config: MyConfig,

    pub fn init(config: MyConfig) MyMiddleware {
        return .{ .config = config };
    }

    pub fn check(self: *MyMiddleware, req: *Request) bool {
        // Return true to continue, false to block
    }
};
```

2. Add to `AppContext` and `applyMiddleware()`

### Adding Lua Functions

Extend `lua/lua.zig` to expose new Zig functions to Lua scripts:

```zig
fn myZigFunction(lua: *ziglua.Lua) i32 {
    // Implementation
    return 1; // Number of return values
}

// Register in ThreadLocalLua.init()
lua.pushFunction(ziglua.wrap(myZigFunction));
lua.setGlobal("myFunction");
```

## Design Principles

### Following Zig Zen

The codebase follows [Zig's design philosophy](https://ziglang.org/documentation/master/#Zen):

1. **Favor reading code over writing code**
   - Clear, explicit control flow
   - Descriptive function and variable names

2. **Don't block the ability to compose**
   - Modular middleware architecture
   - Configurable components

3. **Edge cases matter**
   - Comprehensive error handling
   - Security-focused defaults

4. **Reduce to the essence**
   - Minimal dependencies
   - Reuse standard library and httpz features

### Code Organization Guidelines

1. **One responsibility per module** - Each file has a clear, focused purpose
2. **Explicit over implicit** - No hidden behavior or magic
3. **Compile-time safety** - Leverage Zig's type system
4. **Zero allocations in hot paths** - Use arena allocators
5. **Thread safety** - Mutex protection for shared state

### Performance Considerations

1. **Arena Allocators** - Per-request allocations freed in bulk
2. **Thread-local State** - Lua VMs avoid mutex contention
3. **File Caching** - Configurable cache modes
4. **ETag Support** - Reduce bandwidth with conditional requests
5. **Connection Pooling** - Via httpz's worker model

## Related Documentation

- [HTTP Request Handling](HTTP_REQUEST_HANDLING.md) - Request lifecycle and handler chain design
- [Security Features](SECURITY.md) - Detailed security configuration
- [TLS Setup](TLS_SETUP.md) - HTTPS configuration guide
- [OWASP Compliance](OWASP_COMPLIANCE.md) - Security compliance checklist
- [Performance Tuning](PERFORMANCE_TUNING.md) - Optimization guide
- [Logging](LOGGING.md) - Logging configuration
- [Observability](OBSERVABILITY.md) - Metrics and monitoring
- [ETag Caching](ETAG_CACHING.md) - Cache validation

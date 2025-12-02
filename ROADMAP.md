# zhttpd Roadmap

## Project Status Summary

**Current Version:** v0.6.0 (Production Ready)
**Last Updated:** 2025-12-01

zhttpd has achieved its core objectives and is production-ready. This document provides a comprehensive analysis of the project status, gap analysis for a complete web server, and recommendations for future development.

---

## Quick Status Overview

| Category | Status | Completion |
|----------|--------|------------|
| **Core HTTP Server** | ✅ Complete | 100% |
| **Static File Serving** | ✅ Complete | 100% |
| **Lua Dynamic Content** | ✅ Complete | 100% |
| **Security Features** | ✅ Complete | 95% |
| **Observability** | ✅ Complete | 90% |
| **Database Integration** | ✅ Complete | 85% |
| **Documentation** | ✅ Complete | 95% |

---

## Core Features Status

✅ **HTTP Server (Complete)**
- High-performance HTTP/1.1 server based on http.zig/httpz
- Multi-threaded request handling with configurable thread pool
- Connection pooling and efficient resource management
- Configurable request/response buffer sizes
- Request timeout handling

✅ **Static File Serving (Complete)**
- MIME type detection for all common file types
- ETag-based caching with If-None-Match support
- Cache-Control headers
- Path traversal attack prevention
- Configurable static directory
- Zerocopy cache with reference counting

✅ **Lua Dynamic Content (Complete)**
- LuaJIT as default engine (better performance)
- Lua 5.4 available as fallback option
- Sandboxed execution environment
- Instruction limit protection
- Request/Response/Context API
- Hot-reloading via FileCache auto mode
- Built-in json module for JSON handling
- Module registry caching for optimized script loading

✅ **Security (Complete)**
- Default security headers (CSP, HSTS, X-Frame-Options, etc.)
- Rate limiting with token bucket algorithm
- IP blacklist/whitelist with CIDR support
- Authentication middleware (Lua-delegated)
- CORS middleware
- Request size limits
- TLS via reverse proxy (documented)

✅ **Observability (Complete)**
- Prometheus metrics endpoint (/metrics)
- Health check endpoint (/health)
- X-Request-ID propagation
- Structured JSON logging
- Access logging with duration tracking

✅ **Database (Complete)**
- zdbc integration for SQLite, PostgreSQL, MySQL
- Multi-datasource configuration
- Lua database API (query, exec, begin, commit, rollback)

✅ **Session Management (New)**
- cache.zig integration for thread-safe LRU caching
- In-memory session storage with TTL
- Lua session API via context:session()
- Automatic session cookie handling
- Configurable max sessions, TTL, and cookie options

---

## Gap Analysis: Complete Web Server

### What's Complete (Production Ready)

1. **Request Processing Pipeline**
   - ✅ Request parsing and routing
   - ✅ Middleware chain (IP control → Rate limit → CORS → Auth)
   - ✅ Handler execution
   - ✅ Response generation
   - ✅ Access logging and metrics

2. **Content Delivery**
   - ✅ Static file serving
   - ✅ Dynamic content via Lua
   - ✅ GraphQL API
   - ✅ WebSocket support
   - ✅ Server-Sent Events (SSE)

3. **Security**
   - ✅ OWASP Top 10 compliance review
   - ✅ Input validation
   - ✅ Lua sandbox
   - ✅ Security headers

### What's Missing for Enterprise Production

| Feature | Priority | Effort | Notes |
|---------|----------|--------|-------|
| HTTP/2 Support | Medium | High | Depends on httpz library |
| Response Compression (gzip/brotli) | Medium | Medium | Complex in Zig 0.15 |
| Native TLS | Low | High | Use reverse proxy instead |
| Graceful Shutdown | Medium | Low | Signal handling |
| Configuration Reload | Low | Medium | Hot reload config |
| Request Tracing (OpenTelemetry) | Low | Medium | Distributed tracing |
| Virtual Hosts | Low | Medium | Multiple domain support |
| URL Rewriting | Low | Medium | Rule-based redirects |
| WebDAV Support | Low | High | File management protocol |

### Comparison with Major Web Servers

| Feature | zhttpd | nginx | Apache | Caddy |
|---------|--------|-------|--------|-------|
| Static Files | ✅ | ✅ | ✅ | ✅ |
| Reverse Proxy | ❌ | ✅ | ✅ | ✅ |
| Load Balancing | ❌ | ✅ | ✅ | ✅ |
| HTTP/2 | ❌ | ✅ | ✅ | ✅ |
| Native TLS | ❌ | ✅ | ✅ | ✅ |
| Lua Scripting | ✅ | ✅* | ❌ | ❌ |
| GraphQL | ✅ | ❌ | ❌ | ❌ |
| Config Format | YAML | Custom | Custom | Caddyfile |
| Memory Safety | ✅ | ❌ | ❌ | ✅ |

*nginx requires OpenResty for Lua

---

## Software Engineering Analysis

### 1. Modularity (Rating: ⭐⭐⭐⭐☆)

**Strengths:**
- Clear separation of concerns with dedicated modules:
  - `handlers/` - HTTP request handlers
  - `middleware/` - Composable middleware chain
  - `security/` - Security features
  - `lua/` - Lua integration
  - `graphql/` - GraphQL support
  - `cache/` - File caching
  - `observability/` - Metrics and health
  - `plugins/` - Database plugins
- Each handler is a separate file with clear responsibilities
- Configuration module cleanly separated from runtime

**Areas for Improvement:**
- `httpz_handlers.zig` (961 lines) is the largest file and handles multiple responsibilities
- Consider extracting route registration logic
- Middleware could benefit from a formal registry pattern

**Recommendation:**
```zig
// Consider creating a MiddlewareRegistry for better extensibility
pub const MiddlewareRegistry = struct {
    items: std.ArrayList(MiddlewareEntry),
    pub fn register(self: *MiddlewareRegistry, entry: MiddlewareEntry) !void
    pub fn apply(self: *MiddlewareRegistry, req: *Request, res: *Response) bool
};
```

### 2. Code Reuse (Rating: ⭐⭐⭐⭐⭐)

**Strengths:**
- Excellent use of shared components:
  - `FileCache` - Shared between static files and Lua scripts
  - `Logger` - Centralized logging for all components
  - Security headers applied consistently
- Handler pattern is consistent and reusable
- Middleware follows composable design

**Evidence:**
- FileCache used in static_handler, lua.zig
- Logger used across all handlers
- Security headers reused via `addSecurityHeaders()`

### 3. Memory Management (Rating: ⭐⭐⭐⭐⭐)

**Strengths:**
- Consistent use of arena allocators for per-request allocations
- Proper `errdefer` patterns for cleanup
- Thread-local Lua states avoid mutex contention
- File cache manages its own memory lifecycle

**Key Patterns:**
```zig
// Per-request allocations via response arena
const content = try res.arena.alloc(u8, file_size);

// Proper cleanup with errdefer
const file_cache = try allocator.create(FileCache);
errdefer allocator.destroy(file_cache);
file_cache.* = FileCache.init(allocator, config.reload, config.max_cache_file_size);
errdefer file_cache.deinit();
```

**Areas for Improvement:**
- Thread-local Lua states not explicitly cleaned up (relies on OS cleanup)
- Could add explicit `deinitThreadLocalLua()` call during shutdown

### 4. Performance (Rating: ⭐⭐⭐⭐☆)

**Benchmarks (ReleaseFast):**
- Apache Bench: ~10,500 req/s @ 100 concurrent
- h2load: ~46,000 req/s @ 100 concurrent
- Latency: < 10ms

**Optimizations Applied:**
- Arena allocators for zero-fragmentation
- Thread-local Lua VMs (no mutex contention)
- ETag caching (50-90% bandwidth reduction)
- Configurable connection pools

**Missing Optimizations:**
- Response compression (gzip/brotli)
- HTTP/2 multiplexing
- Zero-copy file serving
- Bytecode caching for Lua (infrastructure exists, not implemented)

### 5. Flexibility (Rating: ⭐⭐⭐⭐⭐)

**Strengths:**
- Highly configurable via YAML/JSON
- 40+ configuration options
- Handler mappings configurable
- Multiple reload modes (never, auto, force)
- Feature flags for all major components

**Configuration Examples:**
```yaml
# Enable/disable features
enable_lua: true
enable_graphql: true
enable_websocket: true
enable_rate_limit: true

# Fine-tune performance
thread_pool_size: 8
max_connections: 1024
request_buffer_size: 65536
```

---

## Interface Analysis

### Internal Interfaces (Zig API)

| Interface | Location | Status | Documentation |
|-----------|----------|--------|---------------|
| `AppContext` | httpz_handlers.zig | ✅ Stable | ✅ Documented |
| `Config` | config/config.zig | ✅ Stable | ✅ Documented |
| `FileCache` | cache/file_cache.zig | ✅ Stable | ⚠️ Partial |
| `LuaHandler` | lua/lua.zig | ✅ Stable | ✅ Documented |
| `RateLimiter` | middleware/rate_limiter.zig | ✅ Stable | ⚠️ Partial |
| `Logger` | logger/logger.zig | ✅ Stable | ✅ Documented |
| `Metrics` | observability/metrics.zig | ✅ Stable | ⚠️ Partial |
| `DbPlugin` | plugins/db/db.zig | ⚠️ Evolving | ⚠️ Partial |
| `SessionManager` | session/session.zig | ✅ Stable | ✅ Documented |

**Recommendations:**
1. Create `docs/API_REFERENCE.md` with all public interfaces
2. Add doc comments to all public functions
3. Version internal APIs for backward compatibility

### External Interfaces (HTTP/Lua API)

| Interface | Endpoint | Status | Documentation |
|-----------|----------|--------|---------------|
| REST API | `/api/*` | ✅ Stable | ✅ Documented |
| GraphQL | `/graphql` | ✅ Stable | ✅ Documented |
| GraphQL Playground | `/graphql/playground` | ✅ Stable | ✅ Documented |
| WebSocket | `/ws`, `/graphql/ws` | ✅ Stable | ✅ Documented |
| SSE | `/events` | ✅ Stable | ⚠️ Partial |
| Health | `/health` | ✅ Stable | ✅ Documented |
| Metrics | `/metrics` | ✅ Stable | ✅ Documented |
| Static Files | `/*` | ✅ Stable | ✅ Documented |

**Lua API (Stable):**
```lua
-- Request API
request:method()      -- GET, POST, etc.
request:path()        -- Request path
request:url()         -- Full URL with query
request:header(name)  -- Get header value
request:headers()     -- All headers as table
request:query(name)   -- Query parameter
request:query_all()   -- All query params
request:body()        -- Parsed body
request:body_raw()    -- Raw body string

-- Response API
response:status(code) -- Set HTTP status
response:header(n, v) -- Set header
response:content_type(type) -- Set content type
response:body(content) -- Set body

-- Database API (via context)
context:db()          -- Get default datasource
context:db("name")    -- Get named datasource
db:query(sql, ...)    -- Execute SELECT
db:exec(sql, ...)     -- Execute INSERT/UPDATE/DELETE
db:begin()            -- Start transaction
db:commit()           -- Commit transaction
db:rollback()         -- Rollback transaction

-- Session API (via context)
context:session()     -- Get or create session
session:id()          -- Get session ID
session:get(key)      -- Get session value
session:set(key, val) -- Set session value
session:delete(key)   -- Delete session value
session:clear()       -- Clear all session data
session:destroy()     -- Destroy session
session:keys()        -- Get all session keys
```

---

## Infrastructure Status

✅ **CI/CD Pipeline**
- GitHub Actions workflow
- Automated build on push/PR
- Unit test execution
- Code format checking

✅ **Testing**
- Unit tests for all major components
- Integration tests for handlers
- Benchmark scripts

✅ **Documentation**
- README.md (comprehensive)
- ROADMAP.md (this file)
- STATUS.md
- docs/ARCHITECTURE.md
- docs/SECURITY.md
- docs/OWASP_COMPLIANCE.md
- docs/LOGGING.md
- docs/PERFORMANCE_TUNING.md
- docs/LUA_PROGRAMMING_GUIDE.md
- docs/HTTP_REQUEST_HANDLING.md

---

## Future Enhancement Opportunities

The following are **optional enhancements** that could be considered for future development, beyond the original project requirements:

### Phase 1: Enhanced Lua Integration

**Priority:** Medium  
**Effort:** Medium
**Status:** ✅ Completed (v0.6.0)

- [x] Pass complex request data structures to Lua scripts (headers, query parameters) - luvit/Node.js style API
- [x] Lua script hot-reloading without server restart - via FileCache auto mode
- [x] Lua script caching and precompilation - source caching with mtime validation (bytecode infrastructure added for future use)
- [x] Sandboxing and resource limits for Lua scripts - instruction limits and dangerous function removal
- [x] LuaJIT as default engine - JIT compilation for better performance (use `-Dlua-lang=lua54` for standard Lua)
- [x] Built-in json module - JSON encode/decode functions available in Lua scripts
- [x] C module integration guide - documentation for using Lua C modules (see docs/LUA_C_MODULES.md)
- [x] Module registry caching - zerocopy loading with registry caching for optimized script loading

### Phase 2: Full GraphQL Implementation

**Priority:** Medium  
**Effort:** High
**Status:** ✅ Completed (v0.5.0)

- [x] Define actual data resolvers with business logic - via Lua resolver API
- [x] GraphQL playground UI - available at /graphql/playground
- [x] Parse GraphQL queries with grapzig library
- [x] Lua-based resolver system for custom data fetching
- [x] Database integration (SQLite; PostgreSQL/MySQL syntax support planned) - via context:db() in Lua resolvers
- [x] GraphQL subscriptions over WebSocket - via /graphql/ws endpoint with Lua handlers
- [x] Schema introspection support (__schema, __type, __typename queries)
- [x] Query complexity analysis and rate limiting (MAX_QUERY_COMPLEXITY, MAX_QUERY_DEPTH)
- [ ] DataLoader pattern for N+1 query optimization - deferred (can be implemented in Lua)

### Phase 3: Advanced httpz Features

**Priority:** Low  
**Effort:** Medium
**Status:** ✅ Completed (v0.2.0)

- [x] WebSocket support (httpz has built-in support) - Full implementation with Lua handlers at /ws
- [x] Server-Side Events (SSE) for real-time updates - Endpoint at /events
- [x] Rate limiting middleware - Token bucket algorithm with per-IP tracking
- [x] Authentication/Authorization middleware (JWT, OAuth) - Lua-delegated validation
- [x] Request logging middleware - Already implemented via access_logger
- [x] CORS middleware with configurable policies - Full CORS header support
- [ ] Request/response compression middleware - Deferred (complex in Zig 0.15)

### Phase 4: Performance & Scalability

**Priority:** Low  
**Effort:** Medium-High
**Status:** ✅ Completed (v0.6.0)

- [x] Static file caching with ETags (COMPLETED: v0.1.1)
- [x] Connection pooling optimizations (COMPLETED: v0.1.2)
- [x] Memory pool tuning and arena optimizations (COMPLETED: v0.1.2)
- [x] Zerocopy cache with reference counting (COMPLETED: v0.6.0)
- [x] Custom LRU cache implementation (COMPLETED: v0.6.0)
- [ ] Response compression (gzip, brotli) - Deferred (complex in Zig 0.15)
- [ ] HTTP/2 support (if httpz supports it) - Depends on httpz library

### Phase 5: Observability

**Priority:** Medium  
**Effort:** Low-Medium
**Status:** ✅ Completed (v0.2.0)

- [x] Metrics endpoint (Prometheus format) - /metrics endpoint with request counts, latency histograms, and more
- [x] Health check endpoint - /health endpoint with component status and uptime
- [x] Request ID propagation - X-Request-ID header propagation across requests
- [x] Structured JSON logging option - log_format: "json" for structured logging
- [ ] Integrate remaining std.debug.print instances - Some debug prints intentionally kept for error handling
- [ ] Distributed tracing support (OpenTelemetry) - Deferred for future

### Phase 6: Developer Experience

**Priority:** Low  
**Effort:** Low

- [ ] Development mode with auto-reload
- [ ] Better error messages and debugging
- [ ] Interactive CLI for server management
- [ ] Docker/container support
- [ ] Deployment guides for common platforms
- [ ] More example applications
- [ ] API documentation generator

### Phase 7: Security Enhancements

**Priority:** High  
**Effort:** Medium  
**Status:** ✅ Completed (v0.4.0)

**Note:** HTTPS/TLS support is essential for production deployments handling sensitive data.

- [x] HTTPS/TLS support (via reverse proxy - nginx/Caddy recommended, see docs/TLS_SETUP.md)
- [x] Certificate management (Let's Encrypt integration documented)
- [x] Request size limits per route (RouteSizeLimiter in security.zig)
- [x] IP-based rate limiting and blacklisting (IpAccessControl with CIDR support)
- [x] Security audit and penetration testing (OWASP Top 10 review completed)
- [x] OWASP compliance review (see docs/OWASP_COMPLIANCE.md)
- [x] Content Security Policy generator (CspGenerator in security.zig)

## Non-Goals

The following are explicitly **not** planned for zhttpd:

- ❌ Full application framework (zhttpd is a web server, not a framework)
- ❌ Built-in ORM or database abstraction layer
- ❌ Template engine (use Lua for dynamic content)
- ❌ Built-in authentication system (should be implemented via middleware)
- ❌ Admin UI or control panel
- ❌ Clustering or distributed deployment (use external load balancers)

## Contributing

Community contributions are welcome! When proposing new features:

1. Check this roadmap to see if it aligns with project goals
2. Open an issue to discuss the feature before implementing
3. Ensure changes maintain performance and security standards
4. Include tests and documentation
5. Follow the existing code style and patterns

## Version Planning

Current Version: **v0.6.0** (Production Ready)

**Version history:**

- **v0.2.x**: Minor enhancements and bug fixes
- **v0.3.x**: Enhanced Lua integration (Phase 1)
- **v0.4.x**: LuaJIT support and json module (Phase 1 complete)
- **v0.5.x**: Full GraphQL implementation (Phase 2 complete)
- **v0.6.x**: Performance optimizations (zerocopy cache, LuaJIT default, module caching)
- **v1.0.0**: Stable API with backward compatibility guarantees

## Maintenance

**Current maintenance status:** Active

- Bug fixes: High priority
- Security patches: Immediate
- Zig version updates: As needed
- Dependency updates: Quarterly review

## Community Feedback

This roadmap is a living document. Community feedback is encouraged:

- Feature requests: Open a GitHub issue
- Priority discussions: GitHub Discussions
- Pull requests: Always welcome with prior discussion

---

**Last Updated:** 2025-12-01  
**Status:** Active Development

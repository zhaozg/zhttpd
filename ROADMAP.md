# zhttpd Roadmap

## Project Status

zhttpd has achieved its core objectives and is production-ready. All primary features have been successfully implemented and tested:

✅ **Core Features Complete:**
- High-performance HTTP server (based on http.zig/httpz)
- Static file serving with proper MIME types
- Lua integration for dynamic content (ziglua)
- GraphQL API support (grapzig)
- Security headers (CSP, HSTS, X-Frame-Options, etc.)
- Comprehensive logging system
- Thread pool for concurrent request handling
- JSON and YAML configuration support

✅ **Infrastructure Complete:**
- CI/CD pipeline with automated testing
- Performance benchmarking (Apache Bench & h2load)
- Unit test suite
- Documentation

## Future Enhancement Opportunities

The following are **optional enhancements** that could be considered for future development, beyond the original project requirements:

### Phase 1: Enhanced Lua Integration

**Priority:** Medium  
**Effort:** Medium
**Status:** ✅ Completed (v0.3.0)

- [x] Pass complex request data structures to Lua scripts (headers, query parameters) - luvit/Node.js style API
- [x] Lua script hot-reloading without server restart - via FileCache auto mode
- [x] Lua script caching and precompilation - source caching with mtime validation (bytecode infrastructure added for future use)
- [x] Sandboxing and resource limits for Lua scripts - instruction limits and dangerous function removal
- [ ] Enhanced Lua response handling with full JSON support - deferred (use cjson in Lua)
- [ ] Built-in Lua libraries for common tasks (JSON, HTTP client, database) - deferred (implement in Lua)

### Phase 2: Full GraphQL Implementation

**Priority:** Medium  
**Effort:** High
**Status:** 🔄 In Progress

- [x] Define actual data resolvers with business logic - via Lua resolver API
- [x] GraphQL playground UI - available at /graphql/playground
- [x] Parse GraphQL queries with grapzig library
- [x] Lua-based resolver system for custom data fetching
- [ ] Database integration (PostgreSQL, SQLite) - deferred (implement in Lua)
- [x] GraphQL subscriptions over WebSocket - via /graphql/ws endpoint with Lua handlers
- [ ] Schema introspection improvements
- [ ] DataLoader pattern for N+1 query optimization
- [ ] Query complexity analysis and rate limiting

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

- [x] Static file caching with ETags (COMPLETED: v0.1.1)
- [x] Connection pooling optimizations (COMPLETED: v0.1.2)
- [x] Memory pool tuning and arena optimizations (COMPLETED: v0.1.2)
- [ ] Response compression (gzip, brotli) - Deferred (complex in Zig 0.15)
- [ ] HTTP/2 support (if httpz supports it) - Depends on httpz library
- [ ] Zero-copy file serving where possible - Requires httpz changes
- [ ] Async I/O improvements - Already optimized by httpz

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

Current Version: **v0.1.0** (Production Ready)

**Future versions will follow semantic versioning:**

- **v0.2.x**: Minor enhancements and bug fixes
- **v0.3.x**: Enhanced Lua integration (Phase 1)
- **v0.4.x**: Full GraphQL implementation (Phase 2)
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

**Last Updated:** 2025-11-26  
**Status:** Active Development

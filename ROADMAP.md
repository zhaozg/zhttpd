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

- [ ] Pass complex request data structures to Lua scripts (headers, query parameters)
- [ ] Enhanced Lua response handling with full JSON support
- [ ] Lua script hot-reloading without server restart
- [ ] Built-in Lua libraries for common tasks (JSON, HTTP client, database)
- [ ] Lua script caching and precompilation
- [ ] Sandboxing and resource limits for Lua scripts

### Phase 2: Full GraphQL Implementation

**Priority:** Medium  
**Effort:** High

- [ ] Define actual data resolvers with business logic
- [ ] Database integration (PostgreSQL, SQLite)
- [ ] GraphQL subscriptions over WebSocket
- [ ] Schema introspection improvements
- [ ] DataLoader pattern for N+1 query optimization
- [ ] GraphQL playground UI
- [ ] Query complexity analysis and rate limiting

### Phase 3: Advanced httpz Features

**Priority:** Low  
**Effort:** Medium

- [ ] WebSocket support (httpz has built-in support)
- [ ] Server-Side Events (SSE) for real-time updates
- [ ] Rate limiting middleware
- [ ] Authentication/Authorization middleware (JWT, OAuth)
- [ ] Request logging middleware
- [ ] CORS middleware with configurable policies
- [ ] Request/response compression middleware

### Phase 4: Performance & Scalability

**Priority:** Low  
**Effort:** Medium-High

- [x] Static file caching with ETags (COMPLETED: v0.1.1)
- [ ] Response compression (gzip, brotli)
- [ ] HTTP/2 support (if httpz supports it)
- [ ] Connection pooling optimizations
- [ ] Memory pool tuning and arena optimizations
- [ ] Zero-copy file serving where possible
- [ ] Async I/O improvements

### Phase 5: Observability

**Priority:** Medium  
**Effort:** Low-Medium

- [ ] Integrate logger throughout codebase (currently has 23 std.debug.print instances that should use the logger)
- [ ] Metrics endpoint (Prometheus format)
- [ ] Health check endpoint
- [ ] Distributed tracing support (OpenTelemetry)
- [ ] Request ID propagation
- [ ] Structured JSON logging option

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

**Note:** HTTPS/TLS support is essential for production deployments handling sensitive data.

- [ ] HTTPS/TLS support (HIGH PRIORITY)
- [ ] Certificate management (Let's Encrypt integration)
- [ ] Request size limits per route
- [ ] IP-based rate limiting and blacklisting
- [ ] Security audit and penetration testing
- [ ] OWASP compliance review
- [ ] Content Security Policy generator

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

# Security Features

## Overview

zhttpd implements multiple layers of security to protect your applications. This document describes the security features available and how to configure them.

## Security Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    Reverse Proxy (TLS)                       │
├─────────────────────────────────────────────────────────────┤
│                    IP Access Control                         │
├─────────────────────────────────────────────────────────────┤
│                    Rate Limiting                             │
├─────────────────────────────────────────────────────────────┤
│                    Authentication                            │
├─────────────────────────────────────────────────────────────┤
│                    CORS / Security Headers                   │
├─────────────────────────────────────────────────────────────┤
│                    Request Validation                        │
├─────────────────────────────────────────────────────────────┤
│                    Lua Sandbox                               │
└─────────────────────────────────────────────────────────────┘
```

## IP Access Control (Phase 7)

Block or allow requests based on client IP address.

### Configuration

```yaml
# Enable IP access control
enable_ip_blacklist: true

# Block specific IPs or CIDR ranges
ip_blacklist: "192.168.1.100, 10.0.0.0/8, 172.16.0.0/12"

# Always allow these IPs (bypass rate limiting)
ip_whitelist: "192.168.1.1, 10.0.0.1"
```

### Features

- **Exact IP matching** - Block/allow specific IP addresses
- **CIDR notation** - Block/allow entire subnets (e.g., `10.0.0.0/8`)
- **Whitelist priority** - Whitelisted IPs bypass blacklist and rate limiting
- **Runtime updates** - Add/remove IPs without restart (via API)
- **Logging** - Blocked requests are logged

### Example: Block known bad actors

```yaml
ip_blacklist: |
  # Known bot networks
  185.234.219.0/24,
  45.155.205.0/24,
  # Specific abuse IPs
  192.0.2.100,
  198.51.100.50
```

## Rate Limiting

Protect against abuse with token bucket rate limiting.

### Configuration

```yaml
enable_rate_limit: true
rate_limit_requests: 100  # Max requests per window
rate_limit_window: 60     # Window in seconds (1 minute)
```

### Features

- **Token bucket algorithm** - Allows burst traffic while maintaining average rate
- **Per-IP tracking** - Each IP has independent limits
- **Burst allowance** - 10 extra requests for sudden traffic spikes
- **Standard headers** - `X-RateLimit-Remaining` and `Retry-After` headers
- **Whitelist bypass** - Whitelisted IPs skip rate limiting

### Response when rate limited

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
Retry-After: 60

{"error":"Too Many Requests","message":"Rate limit exceeded. Please try again later."}
```

## Authentication Middleware

Flexible authentication with Lua-delegated validation.

### Configuration

```yaml
enable_auth: true
auth_script: "auth"                          # Lua script for validation
auth_protected_paths: "/api/*"               # Paths requiring auth
auth_public_paths: "/api/login, /api/register, /api/health"
```

### JWT Example (Lua)

```lua
-- examples/lua/auth.lua
local function validate_jwt(token)
    -- Decode and verify JWT
    -- Return user info if valid
    return { authenticated = true, user_id = "123" }
end

function handle_request(request)
    local token = request.body.token
    local result = validate_jwt(token)
    return result
end

return { handle = handle_request }
```

### Response when unauthorized

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer

{"error":"Unauthorized","message":"Authentication required"}
```

## Security Headers

Default security headers protect against common attacks.

### Enabled by Default

| Header | Value | Protection |
|--------|-------|------------|
| Content-Security-Policy | `default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'` | XSS attacks |
| X-Frame-Options | `SAMEORIGIN` | Clickjacking |
| X-Content-Type-Options | `nosniff` | MIME sniffing |
| X-XSS-Protection | `1; mode=block` | Legacy XSS filter |
| Strict-Transport-Security | `max-age=31536000; includeSubDomains` | Protocol downgrade |
| Referrer-Policy | `strict-origin-when-cross-origin` | Information leakage |
| Permissions-Policy | `geolocation=(), microphone=(), camera=()` | Feature restrictions |

### Configuration

```yaml
security_headers: true  # Enable all security headers
```

### Custom CSP Generator

Generate custom Content Security Policies programmatically:

```zig
const security = @import("security/security.zig");

// Generate API-specific CSP (very restrictive)
const api_csp = try security.CspGenerator.generateApiCsp(allocator);
// Result: "default-src 'none'; frame-ancestors 'none'"

// Generate web page CSP
const web_csp = try security.CspGenerator.generateWebCsp(allocator);
// Result: Full CSP with common web sources
```

## CORS (Cross-Origin Resource Sharing)

Control cross-origin requests to your API.

### Configuration

```yaml
enable_cors: true
cors_origins: "https://example.com, https://app.example.com"
cors_methods: "GET, POST, PUT, DELETE, OPTIONS"
cors_headers: "Content-Type, Authorization, X-Request-ID"
```

### Preflight Responses

OPTIONS requests receive appropriate CORS headers with `Access-Control-Max-Age` for caching.

## Lua Sandbox

Secure execution environment for Lua scripts.

### Configuration

```yaml
lua_sandbox_enabled: true      # Enable sandbox (default)
lua_max_instructions: 100000   # Limit CPU usage (0 = unlimited)
```

### Removed Functions

The sandbox removes dangerous functions:

- `os.execute` - Shell command execution
- `io.popen` - Process creation
- `loadfile` / `dofile` - File system access
- `package` module - Prevents loading external modules
- `debug` module - Prevents introspection

### Instruction Limits

Prevents infinite loops and CPU abuse:

```lua
-- This will be terminated after 100,000 instructions
while true do
    -- Infinite loop
end
```

## Request Validation

### Path Traversal Prevention

All file paths are validated to prevent directory traversal:

```
GET /../../../etc/passwd  →  400 Bad Request
GET /static/../../../etc/passwd  →  400 Bad Request
```

### Body Size Limits

```yaml
max_body_size: 10485760  # 10MB global limit
```

### Request Timeout

```yaml
timeout_seconds: 30  # Request timeout
```

## Logging and Monitoring

### Access Logging

```yaml
access_log_file: "access.log"
log_format: "json"  # Structured logging
```

### Request ID Propagation

```yaml
enable_request_id: true  # X-Request-ID header
```

### Metrics

```yaml
enable_metrics: true  # Prometheus metrics at /metrics
```

### Health Checks

```yaml
enable_health_check: true  # Health status at /health
```

## Best Practices

### 1. Always Use TLS

Deploy behind a reverse proxy with TLS. See [TLS_SETUP.md](TLS_SETUP.md).

### 2. Enable All Security Features

```yaml
security_headers: true
enable_rate_limit: true
enable_ip_blacklist: true
enable_auth: true  # For protected endpoints
lua_sandbox_enabled: true
```

### 3. Monitor and Log

```yaml
enable_metrics: true
enable_health_check: true
enable_request_id: true
log_format: "json"
access_log_file: "access.log"
```

### 4. Regular Updates

Keep zhttpd and its dependencies updated:

```bash
# Check for updates to build.zig.zon dependencies
```

### 5. Minimal Attack Surface

- Disable unused features (GraphQL, WebSocket if not needed)
- Restrict Lua scripts to necessary operations
- Use specific CORS origins instead of `*`

## Security Checklist

- [ ] TLS enabled via reverse proxy
- [ ] Security headers enabled
- [ ] Rate limiting configured
- [ ] IP blacklist configured (if needed)
- [ ] Authentication enabled for protected paths
- [ ] Lua sandbox enabled
- [ ] Logging and monitoring enabled
- [ ] Regular security updates scheduled

## Reporting Security Issues

Please report security vulnerabilities responsibly. Do not open public issues for security problems. Contact the maintainers directly.

# OWASP Compliance Review

## Overview

This document provides an analysis of zhttpd's compliance with the OWASP (Open Web Application Security Project) Top 10 and other security best practices.

## OWASP Top 10 (2021) Compliance Status

### A01:2021 – Broken Access Control ✅ Addressed

**Status:** Mitigated

**zhttpd Implementation:**
- **Authentication middleware** - JWT/OAuth validation delegated to Lua scripts
- **Protected paths configuration** - Configurable protected/public path patterns
- **Path traversal prevention** - Blocks `..` in file paths
- **Rate limiting** - Token bucket algorithm prevents brute force attacks
- **IP blacklisting** - Block malicious IPs at the network level

**Configuration:**
```yaml
enable_auth: true
auth_protected_paths: "/api/*"
auth_public_paths: "/api/login, /api/register, /health"
enable_rate_limit: true
rate_limit_requests: 100
rate_limit_window: 60
enable_ip_blacklist: true
ip_blacklist: "10.0.0.0/8"  # Example: block internal network
```

### A02:2021 – Cryptographic Failures ⚠️ Requires External TLS

**Status:** Partially Addressed (requires reverse proxy)

**zhttpd Implementation:**
- **HSTS header** - Enforces HTTPS connections
- **TLS via reverse proxy** - nginx/Caddy/HAProxy recommended
- **No sensitive data in logs** - Sanitized log output

**Recommendation:**
Always deploy behind a TLS-terminating reverse proxy. See [TLS_SETUP.md](TLS_SETUP.md).

### A03:2021 – Injection ✅ Addressed

**Status:** Mitigated

**zhttpd Implementation:**
- **Lua sandboxing** - Dangerous functions removed from Lua environment
- **JSON escaping** - All user inputs escaped in JSON responses
- **Log sanitization** - Control characters removed from log entries
- **Path validation** - Prevents path traversal attacks

**Code Examples:**
```zig
// Path traversal prevention
if (std.mem.indexOf(u8, clean_path, "..") != null) {
    res.status = 400;
    res.body = "Bad Request";
    return;
}

// Log sanitization
fn sanitizeLogField(buf: []u8, input: []const u8) []const u8 {
    // Removes newlines and control characters
}
```

### A04:2021 – Insecure Design ✅ Addressed

**Status:** Mitigated by Design

**zhttpd Implementation:**
- **Defense in depth** - Multiple security layers (middleware, headers, validation)
- **Secure defaults** - Security headers enabled by default
- **Least privilege** - Lua sandbox restricts dangerous operations
- **Fail-safe defaults** - Conservative error handling

### A05:2021 – Security Misconfiguration ✅ Addressed

**Status:** Mitigated

**zhttpd Implementation:**
- **Secure defaults** - All security features enabled by default
- **Security headers** - CSP, HSTS, X-Frame-Options, etc.
- **Minimal attack surface** - Only necessary endpoints exposed
- **Configurable logging** - Structured JSON logging option

**Default Security Headers:**
```
Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Strict-Transport-Security: max-age=31536000; includeSubDomains
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), microphone=(), camera=()
```

### A06:2021 – Vulnerable and Outdated Components ⚠️ Ongoing

**Status:** Requires Monitoring

**zhttpd Dependencies:**
- httpz (http.zig) - Active development
- ziglua - Active development

**Recommendations:**
1. Regularly update dependencies in `build.zig.zon`
2. Monitor security advisories for Zig and dependencies
3. Subscribe to GitHub security alerts

### A07:2021 – Identification and Authentication Failures ✅ Addressed

**Status:** Mitigated

**zhttpd Implementation:**
- **Token-based auth** - JWT/OAuth support via Lua
- **Rate limiting** - Prevents credential stuffing
- **Session management** - Delegated to application layer (Lua)
- **Configurable auth paths** - Fine-grained access control

### A08:2021 – Software and Data Integrity Failures ⚠️ Application Responsibility

**Status:** Partially Addressed

**zhttpd Implementation:**
- **ETag caching** - Ensures file integrity
- **Lua script caching** - mtime validation for script updates

**Recommendations:**
1. Implement Subresource Integrity (SRI) in HTML
2. Sign Lua scripts in production
3. Use Content-Security-Policy to restrict script sources

### A09:2021 – Security Logging and Monitoring Failures ✅ Addressed

**Status:** Fully Implemented

**zhttpd Implementation:**
- **Structured logging** - JSON format support
- **Access logging** - Detailed request logging
- **Request ID propagation** - X-Request-ID for tracing
- **Metrics endpoint** - Prometheus format for monitoring
- **Health check endpoint** - Component status monitoring

**Configuration:**
```yaml
log_format: "json"
log_level: "info"
access_log_file: "access.log"
enable_metrics: true
enable_health_check: true
enable_request_id: true
```

### A10:2021 – Server-Side Request Forgery (SSRF) ⚠️ Application Responsibility

**Status:** Partially Addressed

**zhttpd Implementation:**
- **No built-in HTTP client** - SSRF via Lua must be handled by scripts
- **Lua sandbox** - Limits dangerous operations

**Recommendations:**
1. Validate URLs in Lua scripts before making requests
2. Implement allowlist for external domains
3. Block requests to internal network ranges

## Additional Security Features

### IP Access Control

zhttpd includes IP-based access control with blacklist/whitelist support:

```yaml
enable_ip_blacklist: true
ip_blacklist: "10.0.0.0/8, 192.168.0.0/16"  # Block internal networks
ip_whitelist: "10.0.0.1"  # Allow specific admin IP
```

### Content Security Policy Generator

zhttpd includes a CSP generator for creating customized policies:

```zig
const generator = CspGenerator.init(.{
    .default_src = .{ .sources = &[_][]const u8{"'self'"} },
    .script_src = .{ .sources = &[_][]const u8{"'self'", "'unsafe-inline'"} },
    .upgrade_insecure_requests = true,
});
const csp = try generator.generate(allocator);
```

### Lua Sandbox

The Lua sandbox removes dangerous functions:

- `os.execute` - Command execution
- `io.popen` - Process creation
- `loadfile` - File loading
- `dofile` - File execution
- `package` - Module system

## Security Checklist

### Pre-Deployment

- [ ] TLS configured via reverse proxy
- [ ] Strong TLS ciphers enabled
- [ ] HSTS enabled with preload
- [ ] Security headers verified
- [ ] Rate limiting configured
- [ ] Authentication enabled for protected paths
- [ ] Logging configured
- [ ] Metrics/monitoring enabled
- [ ] IP blacklist configured (if needed)

### Regular Maintenance

- [ ] Dependencies updated monthly
- [ ] Security advisories reviewed weekly
- [ ] Logs reviewed for anomalies
- [ ] TLS certificates renewed
- [ ] Access patterns analyzed

### Incident Response

- [ ] Log aggregation configured
- [ ] Alerting on security events
- [ ] IP blocking procedure documented
- [ ] Rollback procedure tested

## Security Testing Tools

### Recommended Tools

1. **OWASP ZAP** - Web application security scanner
2. **Burp Suite** - Security testing platform
3. **SSL Labs** - TLS configuration testing
4. **nmap** - Network security auditing
5. **nikto** - Web server scanner

### Testing Commands

```bash
# TLS testing
nmap --script ssl-enum-ciphers -p 443 example.com

# Security headers testing
curl -sI https://example.com | grep -E '^(X-|Content-Security|Strict)'

# Rate limiting testing
for i in {1..150}; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/; done | sort | uniq -c

# Path traversal testing
curl http://localhost:8080/../../../etc/passwd
```

## Reporting Security Issues

If you discover a security vulnerability in zhttpd:

1. **Do NOT** open a public issue
2. Email the maintainers directly (see SECURITY.md if available)
3. Provide detailed reproduction steps
4. Allow 90 days for a fix before public disclosure

## See Also

- [TLS Setup Guide](TLS_SETUP.md)
- [OWASP Top 10](https://owasp.org/Top10/)
- [OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/)
- [Mozilla Web Security Guidelines](https://infosec.mozilla.org/guidelines/web_security)

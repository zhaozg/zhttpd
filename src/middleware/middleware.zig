// zhttpd middleware module
// Provides rate limiting, CORS, and authentication middleware
//
// This module implements a composable middleware chain for HTTP request processing.
// Each middleware component follows a consistent pattern:
//
// 1. Configuration via a Config struct
// 2. Initialization via init() method
// 3. Request checking via a check-style method that returns bool (continue/block)
// 4. Thread-safe design with mutex protection where needed
// 5. Cleanup via deinit() method
//
// Middleware Execution Order (in applyMiddleware):
// 1. IP Access Control - Block/allow based on IP blacklist/whitelist
// 2. Rate Limiting - Token bucket rate limiting per IP
// 3. CORS - Cross-origin resource sharing headers
// 4. Authentication - Token validation (delegated to Lua)
//
// To add a new middleware:
// 1. Create a new file in middleware/ following the existing patterns
// 2. Export the types in this module
// 3. Add the middleware to AppContext in handlers/context.zig
// 4. Add the check in applyMiddleware() function in server.zig
//
// See docs/HTTP_REQUEST_HANDLING.md for detailed design documentation.

pub const rate_limiter = @import("rate_limiter.zig");
pub const cors = @import("cors.zig");
pub const auth = @import("auth.zig");

/// Rate limiting middleware - Token bucket algorithm with per-IP tracking
pub const RateLimiter = rate_limiter.RateLimiter;

/// IP access control - Blacklist/whitelist with CIDR support
pub const IpAccessControl = rate_limiter.IpAccessControl;

/// Result of IP access check
pub const IpAccessResult = rate_limiter.IpAccessResult;

/// CORS configuration options
pub const CorsConfig = cors.CorsConfig;

/// CORS middleware - Cross-origin resource sharing
pub const CorsMiddleware = cors.CorsMiddleware;

/// Authentication configuration options
pub const AuthConfig = auth.AuthConfig;

/// Authentication middleware - Lua-delegated token validation
pub const AuthMiddleware = auth.AuthMiddleware;

/// Result of authentication check
pub const AuthResult = auth.AuthResult;

test {
    _ = rate_limiter;
    _ = cors;
    _ = auth;
}

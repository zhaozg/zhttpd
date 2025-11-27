// zhttpd middleware module
// Provides rate limiting, CORS, and authentication middleware

pub const rate_limiter = @import("rate_limiter.zig");
pub const cors = @import("cors.zig");
pub const auth = @import("auth.zig");

pub const RateLimiter = rate_limiter.RateLimiter;
pub const CorsConfig = cors.CorsConfig;
pub const CorsMiddleware = cors.CorsMiddleware;
pub const AuthConfig = auth.AuthConfig;
pub const AuthMiddleware = auth.AuthMiddleware;
pub const AuthResult = auth.AuthResult;

test {
    _ = rate_limiter;
    _ = cors;
    _ = auth;
}

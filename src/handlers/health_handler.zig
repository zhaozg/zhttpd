//! Health Check Handler
//!
//! Returns server health status in JSON format.
//! Useful for load balancers and Kubernetes probes.

const std = @import("std");
const httpz = @import("httpz");
const observability = @import("../observability/observability.zig");

/// Handle health check requests
pub fn handle(ctx_ptr: *anyopaque, _: *httpz.Request, res: *httpz.Response) !void {
    const ctx = @as(*@import("httpz_handlers.zig").AppContext, @ptrCast(@alignCast(ctx_ptr)));

    // Generate health check
    var health = observability.health.check(
        ctx.start_time,
        ctx.config.enable_lua,
        ctx.config.enable_graphql,
    );

    const status = health.httpStatusCode();
    res.status = status;

    // Return detailed JSON response
    const json = try health.toJson(res.arena);
    res.body = json;
    res.content_type = httpz.ContentType.JSON;

    // Add cache control headers - health checks shouldn't be cached
    res.headers.add("Cache-Control", "no-cache, no-store, must-revalidate");
}

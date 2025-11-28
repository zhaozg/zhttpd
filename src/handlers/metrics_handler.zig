//! Metrics Handler
//!
//! Returns Prometheus metrics in text exposition format.
//! Exposes request counts, latency histograms, error rates, etc.

const std = @import("std");
const httpz = @import("httpz");
const AppContext = @import("httpz_handlers.zig").AppContext;

/// Handle metrics requests
pub fn handle(ctx: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    if (ctx.metrics) |metrics| {
        const output = try metrics.toPrometheus(res.arena);
        res.body = output;
        // Prometheus text format content type
        res.headers.add("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    } else {
        res.status = 503;
        res.body = "Metrics not enabled";
    }

    // Add cache control headers - metrics should be fresh
    res.headers.add("Cache-Control", "no-cache, no-store, must-revalidate");
}

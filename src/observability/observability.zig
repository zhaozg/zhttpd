// zhttpd Observability module
// Provides metrics, health checks, request ID propagation, and structured logging
//
// Components:
// - Metrics: Prometheus-compatible metrics collection
// - Health: Health check endpoints
// - Request ID: Request ID generation and propagation

pub const metrics = @import("metrics.zig");
pub const health = @import("health.zig");
pub const request_id = @import("request_id.zig");

pub const Metrics = metrics.Metrics;
pub const Counter = metrics.Counter;
pub const Gauge = metrics.Gauge;
pub const Histogram = metrics.Histogram;

pub const HealthCheck = health.HealthCheck;
pub const ComponentStatus = health.ComponentStatus;

pub const REQUEST_ID_HEADER = request_id.HEADER_NAME;

test {
    _ = metrics;
    _ = health;
    _ = request_id;
}

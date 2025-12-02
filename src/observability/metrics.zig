// zhttpd Metrics module
// Provides Prometheus-compatible metrics collection and exposure
//
// Metrics are collected using atomic operations for thread-safety
// and exported in Prometheus text format at /metrics endpoint

const std = @import("std");

/// Counter metrics (monotonically increasing)
pub const Counter = struct {
    value: std.atomic.Value(u64),

    pub fn init() Counter {
        return .{ .value = std.atomic.Value(u64).init(0) };
    }

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }
};

/// Gauge metrics (can go up and down)
pub const Gauge = struct {
    value: std.atomic.Value(i64),

    pub fn init() Gauge {
        return .{ .value = std.atomic.Value(i64).init(0) };
    }

    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .monotonic);
    }

    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn add(self: *Gauge, n: i64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }

    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

/// Histogram buckets for response time tracking (in milliseconds)
pub const LATENCY_BUCKETS = [_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 };

/// Simple histogram for response times
pub const Histogram = struct {
    buckets: [LATENCY_BUCKETS.len]std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    sum: std.atomic.Value(u64), // Sum in microseconds for precision

    pub fn init() Histogram {
        var h: Histogram = undefined;
        for (&h.buckets) |*b| {
            b.* = std.atomic.Value(u64).init(0);
        }
        h.count = std.atomic.Value(u64).init(0);
        h.sum = std.atomic.Value(u64).init(0);
        return h;
    }

    /// Observe a value in milliseconds
    /// Each bucket stores the count of observations that fall into that specific bucket range
    /// In Prometheus format, buckets are cumulative (le=X means all observations <= X)
    pub fn observe(self: *Histogram, value_ms: f64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.sum.fetchAdd(@intFromFloat(value_ms * 1000.0), .monotonic); // Store in microseconds

        // Find the appropriate bucket and increment it
        // Each bucket stores only the count for its specific range
        for (LATENCY_BUCKETS, 0..) |bound, i| {
            if (value_ms <= bound) {
                _ = self.buckets[i].fetchAdd(1, .monotonic);
                break; // Only increment the first matching bucket
            }
        }
        // If value_ms exceeds all bucket bounds, it's still counted in count/sum
        // but not in any bucket (will show in +Inf)
    }

    pub fn getCount(self: *const Histogram) u64 {
        return self.count.load(.monotonic);
    }

    pub fn getSum(self: *const Histogram) f64 {
        return @as(f64, @floatFromInt(self.sum.load(.monotonic))) / 1000.0;
    }

    pub fn getBucket(self: *const Histogram, index: usize) u64 {
        return self.buckets[index].load(.monotonic);
    }
};

/// Global metrics registry
/// All metrics are static for thread-safe access across workers
pub const Metrics = struct {
    // HTTP request counters
    requests_total: Counter,
    requests_success: Counter,
    requests_error: Counter,

    // HTTP response status code counters
    responses_2xx: Counter,
    responses_3xx: Counter,
    responses_4xx: Counter,
    responses_5xx: Counter,

    // Connection metrics
    active_connections: Gauge,
    total_connections: Counter,

    // Response time histogram
    request_duration_ms: Histogram,

    // Bytes transferred
    bytes_sent: Counter,
    bytes_received: Counter,

    // Lua script execution
    lua_executions: Counter,
    lua_errors: Counter,

    // WebSocket metrics
    websocket_connections: Gauge,
    websocket_messages_received: Counter,
    websocket_messages_sent: Counter,

    // Rate limiting
    rate_limit_hits: Counter,

    // Cache metrics (Phase 2 optimization tracking)
    ip_access_cache_hits: Counter,
    ip_access_cache_misses: Counter,
    cors_cache_hits: Counter,
    cors_cache_misses: Counter,

    // Server info
    start_time: i64,

    pub fn init() Metrics {
        return .{
            .requests_total = Counter.init(),
            .requests_success = Counter.init(),
            .requests_error = Counter.init(),
            .responses_2xx = Counter.init(),
            .responses_3xx = Counter.init(),
            .responses_4xx = Counter.init(),
            .responses_5xx = Counter.init(),
            .active_connections = Gauge.init(),
            .total_connections = Counter.init(),
            .request_duration_ms = Histogram.init(),
            .bytes_sent = Counter.init(),
            .bytes_received = Counter.init(),
            .lua_executions = Counter.init(),
            .lua_errors = Counter.init(),
            .websocket_connections = Gauge.init(),
            .websocket_messages_received = Counter.init(),
            .websocket_messages_sent = Counter.init(),
            .rate_limit_hits = Counter.init(),
            .ip_access_cache_hits = Counter.init(),
            .ip_access_cache_misses = Counter.init(),
            .cors_cache_hits = Counter.init(),
            .cors_cache_misses = Counter.init(),
            .start_time = std.time.timestamp(),
        };
    }

    /// Record an HTTP request
    pub fn recordRequest(self: *Metrics, status: u16, duration_us: i64, bytes: usize) void {
        self.requests_total.inc();
        self.bytes_sent.add(@intCast(bytes));

        // Convert microseconds to milliseconds for histogram
        const duration_ms: f64 = @as(f64, @floatFromInt(duration_us)) / 1000.0;
        self.request_duration_ms.observe(duration_ms);

        // Categorize by status code
        if (status >= 200 and status < 300) {
            self.responses_2xx.inc();
            self.requests_success.inc();
        } else if (status >= 300 and status < 400) {
            self.responses_3xx.inc();
            self.requests_success.inc();
        } else if (status >= 400 and status < 500) {
            self.responses_4xx.inc();
            self.requests_error.inc();
        } else if (status >= 500) {
            self.responses_5xx.inc();
            self.requests_error.inc();
        }
    }

    /// Export metrics in Prometheus text format
    pub fn toPrometheus(self: *const Metrics, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);

        const writer = buf.writer(allocator);

        // Server info
        try writer.print("# HELP zhttpd_start_time_seconds Unix timestamp of server start time\n", .{});
        try writer.print("# TYPE zhttpd_start_time_seconds gauge\n", .{});
        try writer.print("zhttpd_start_time_seconds {d}\n\n", .{self.start_time});

        // Request counters
        try writer.print("# HELP zhttpd_http_requests_total Total number of HTTP requests\n", .{});
        try writer.print("# TYPE zhttpd_http_requests_total counter\n", .{});
        try writer.print("zhttpd_http_requests_total {d}\n\n", .{self.requests_total.get()});

        try writer.print("# HELP zhttpd_http_requests_success_total Total successful HTTP requests (2xx, 3xx)\n", .{});
        try writer.print("# TYPE zhttpd_http_requests_success_total counter\n", .{});
        try writer.print("zhttpd_http_requests_success_total {d}\n\n", .{self.requests_success.get()});

        try writer.print("# HELP zhttpd_http_requests_error_total Total failed HTTP requests (4xx, 5xx)\n", .{});
        try writer.print("# TYPE zhttpd_http_requests_error_total counter\n", .{});
        try writer.print("zhttpd_http_requests_error_total {d}\n\n", .{self.requests_error.get()});

        // Response status codes
        try writer.print("# HELP zhttpd_http_responses_total Total HTTP responses by status code class\n", .{});
        try writer.print("# TYPE zhttpd_http_responses_total counter\n", .{});
        try writer.print("zhttpd_http_responses_total{{status_class=\"2xx\"}} {d}\n", .{self.responses_2xx.get()});
        try writer.print("zhttpd_http_responses_total{{status_class=\"3xx\"}} {d}\n", .{self.responses_3xx.get()});
        try writer.print("zhttpd_http_responses_total{{status_class=\"4xx\"}} {d}\n", .{self.responses_4xx.get()});
        try writer.print("zhttpd_http_responses_total{{status_class=\"5xx\"}} {d}\n\n", .{self.responses_5xx.get()});

        // Connection metrics
        try writer.print("# HELP zhttpd_connections_active Current number of active connections\n", .{});
        try writer.print("# TYPE zhttpd_connections_active gauge\n", .{});
        try writer.print("zhttpd_connections_active {d}\n\n", .{self.active_connections.get()});

        try writer.print("# HELP zhttpd_connections_total Total number of connections handled\n", .{});
        try writer.print("# TYPE zhttpd_connections_total counter\n", .{});
        try writer.print("zhttpd_connections_total {d}\n\n", .{self.total_connections.get()});

        // Request duration histogram
        try writer.print("# HELP zhttpd_http_request_duration_ms HTTP request duration in milliseconds\n", .{});
        try writer.print("# TYPE zhttpd_http_request_duration_ms histogram\n", .{});

        // Histogram buckets - each bucket contains cumulative count of observations <= bound
        var cumulative: u64 = 0;
        for (LATENCY_BUCKETS, 0..) |bound, i| {
            const bucket_count = self.request_duration_ms.getBucket(i);
            cumulative += bucket_count;
            try writer.print("zhttpd_http_request_duration_ms_bucket{{le=\"{d}\"}} {d}\n", .{ bound, cumulative });
        }
        try writer.print("zhttpd_http_request_duration_ms_bucket{{le=\"+Inf\"}} {d}\n", .{self.request_duration_ms.getCount()});
        try writer.print("zhttpd_http_request_duration_ms_sum {d:.3}\n", .{self.request_duration_ms.getSum()});
        try writer.print("zhttpd_http_request_duration_ms_count {d}\n\n", .{self.request_duration_ms.getCount()});

        // Bytes transferred
        try writer.print("# HELP zhttpd_bytes_sent_total Total bytes sent to clients\n", .{});
        try writer.print("# TYPE zhttpd_bytes_sent_total counter\n", .{});
        try writer.print("zhttpd_bytes_sent_total {d}\n\n", .{self.bytes_sent.get()});

        try writer.print("# HELP zhttpd_bytes_received_total Total bytes received from clients\n", .{});
        try writer.print("# TYPE zhttpd_bytes_received_total counter\n", .{});
        try writer.print("zhttpd_bytes_received_total {d}\n\n", .{self.bytes_received.get()});

        // Lua metrics
        try writer.print("# HELP zhttpd_lua_executions_total Total Lua script executions\n", .{});
        try writer.print("# TYPE zhttpd_lua_executions_total counter\n", .{});
        try writer.print("zhttpd_lua_executions_total {d}\n\n", .{self.lua_executions.get()});

        try writer.print("# HELP zhttpd_lua_errors_total Total Lua script errors\n", .{});
        try writer.print("# TYPE zhttpd_lua_errors_total counter\n", .{});
        try writer.print("zhttpd_lua_errors_total {d}\n\n", .{self.lua_errors.get()});

        // GraphQL metrics
        // WebSocket metrics
        try writer.print("# HELP zhttpd_websocket_connections_active Current WebSocket connections\n", .{});
        try writer.print("# TYPE zhttpd_websocket_connections_active gauge\n", .{});
        try writer.print("zhttpd_websocket_connections_active {d}\n\n", .{self.websocket_connections.get()});

        try writer.print("# HELP zhttpd_websocket_messages_received_total Total WebSocket messages received\n", .{});
        try writer.print("# TYPE zhttpd_websocket_messages_received_total counter\n", .{});
        try writer.print("zhttpd_websocket_messages_received_total {d}\n\n", .{self.websocket_messages_received.get()});

        try writer.print("# HELP zhttpd_websocket_messages_sent_total Total WebSocket messages sent\n", .{});
        try writer.print("# TYPE zhttpd_websocket_messages_sent_total counter\n", .{});
        try writer.print("zhttpd_websocket_messages_sent_total {d}\n\n", .{self.websocket_messages_sent.get()});

        // Rate limiting
        try writer.print("# HELP zhttpd_rate_limit_hits_total Total rate limit rejections\n", .{});
        try writer.print("# TYPE zhttpd_rate_limit_hits_total counter\n", .{});
        try writer.print("zhttpd_rate_limit_hits_total {d}\n\n", .{self.rate_limit_hits.get()});

        // Cache metrics (Phase 2 optimization tracking)
        try writer.print("# HELP zhttpd_ip_access_cache_hits_total IP access cache hits\n", .{});
        try writer.print("# TYPE zhttpd_ip_access_cache_hits_total counter\n", .{});
        try writer.print("zhttpd_ip_access_cache_hits_total {d}\n\n", .{self.ip_access_cache_hits.get()});

        try writer.print("# HELP zhttpd_ip_access_cache_misses_total IP access cache misses\n", .{});
        try writer.print("# TYPE zhttpd_ip_access_cache_misses_total counter\n", .{});
        try writer.print("zhttpd_ip_access_cache_misses_total {d}\n\n", .{self.ip_access_cache_misses.get()});

        try writer.print("# HELP zhttpd_cors_cache_hits_total CORS origin cache hits\n", .{});
        try writer.print("# TYPE zhttpd_cors_cache_hits_total counter\n", .{});
        try writer.print("zhttpd_cors_cache_hits_total {d}\n\n", .{self.cors_cache_hits.get()});

        try writer.print("# HELP zhttpd_cors_cache_misses_total CORS origin cache misses\n", .{});
        try writer.print("# TYPE zhttpd_cors_cache_misses_total counter\n", .{});
        try writer.print("zhttpd_cors_cache_misses_total {d}\n", .{self.cors_cache_misses.get()});

        return try buf.toOwnedSlice(allocator);
    }
};

/// Global metrics instance
var global_metrics: ?*Metrics = null;

/// Initialize global metrics
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    if (global_metrics != null) return;
    global_metrics = try allocator.create(Metrics);
    global_metrics.?.* = Metrics.init();
}

/// Get global metrics instance
pub fn getGlobal() ?*Metrics {
    return global_metrics;
}

/// Deinitialize global metrics
pub fn deinitGlobal(allocator: std.mem.Allocator) void {
    if (global_metrics) |m| {
        allocator.destroy(m);
        global_metrics = null;
    }
}

// Tests
test "counter basic operations" {
    var counter = Counter.init();
    try std.testing.expect(counter.get() == 0);

    counter.inc();
    try std.testing.expect(counter.get() == 1);

    counter.add(5);
    try std.testing.expect(counter.get() == 6);
}

test "gauge basic operations" {
    var gauge = Gauge.init();
    try std.testing.expect(gauge.get() == 0);

    gauge.inc();
    try std.testing.expect(gauge.get() == 1);

    gauge.dec();
    try std.testing.expect(gauge.get() == 0);

    gauge.set(100);
    try std.testing.expect(gauge.get() == 100);

    gauge.add(-50);
    try std.testing.expect(gauge.get() == 50);
}

test "histogram basic operations" {
    var hist = Histogram.init();
    try std.testing.expect(hist.getCount() == 0);

    hist.observe(5.0);
    try std.testing.expect(hist.getCount() == 1);

    hist.observe(50.0);
    hist.observe(500.0);
    try std.testing.expect(hist.getCount() == 3);
}

test "metrics prometheus format" {
    const allocator = std.testing.allocator;

    var metrics = Metrics.init();
    metrics.recordRequest(200, 1000, 1024); // 1ms request
    metrics.recordRequest(404, 500, 128); // 0.5ms request

    const output = try metrics.toPrometheus(allocator);
    defer allocator.free(output);

    // Check that output contains expected metrics
    try std.testing.expect(std.mem.indexOf(u8, output, "zhttpd_http_requests_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zhttpd_http_responses_total{status_class=\"2xx\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zhttpd_http_responses_total{status_class=\"4xx\"} 1") != null);
}

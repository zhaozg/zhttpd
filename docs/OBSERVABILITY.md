# zhttpd Observability

## Overview

zhttpd provides comprehensive observability features for monitoring, debugging, and tracing HTTP requests. This includes:

- **Prometheus Metrics** - Export metrics in Prometheus text format
- **Health Check** - Detailed health status endpoint
- **Request ID Propagation** - Trace requests across services
- **Structured JSON Logging** - Machine-parseable log output

## Configuration

All observability features can be configured in `zhttpd.yaml` or `config.json`:

```yaml
# Phase 5: Observability
# -----------------------

# Prometheus Metrics
enable_metrics: true  # Enable Prometheus metrics endpoint at /metrics

# Health Check
enable_health_check: true  # Enable health check endpoint at /health

# Request ID Propagation
enable_request_id: true  # Enable X-Request-ID header propagation

# Structured Logging
log_format: "text"  # Log format: "text" or "json"
```

## Prometheus Metrics

When `enable_metrics: true`, a Prometheus-compatible metrics endpoint is available at `/metrics`.

### Available Metrics

| Metric Name | Type | Description |
|-------------|------|-------------|
| `zhttpd_start_time_seconds` | Gauge | Unix timestamp of server start time |
| `zhttpd_http_requests_total` | Counter | Total number of HTTP requests |
| `zhttpd_http_requests_success_total` | Counter | Total successful HTTP requests (2xx, 3xx) |
| `zhttpd_http_requests_error_total` | Counter | Total failed HTTP requests (4xx, 5xx) |
| `zhttpd_http_responses_total` | Counter | HTTP responses by status code class (2xx, 3xx, 4xx, 5xx) |
| `zhttpd_connections_active` | Gauge | Current number of active connections |
| `zhttpd_connections_total` | Counter | Total connections handled |
| `zhttpd_http_request_duration_ms` | Histogram | Request duration in milliseconds |
| `zhttpd_bytes_sent_total` | Counter | Total bytes sent to clients |
| `zhttpd_bytes_received_total` | Counter | Total bytes received from clients |
| `zhttpd_lua_executions_total` | Counter | Total Lua script executions |
| `zhttpd_lua_errors_total` | Counter | Total Lua script errors |
| `zhttpd_websocket_connections_active` | Gauge | Current WebSocket connections |
| `zhttpd_websocket_messages_received_total` | Counter | Total WebSocket messages received |
| `zhttpd_websocket_messages_sent_total` | Counter | Total WebSocket messages sent |
| `zhttpd_rate_limit_hits_total` | Counter | Total rate limit rejections |

### Latency Histogram Buckets

The `zhttpd_http_request_duration_ms` histogram uses the following bucket boundaries (in milliseconds):
- 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000

### Example Output

```
# HELP zhttpd_http_requests_total Total number of HTTP requests
# TYPE zhttpd_http_requests_total counter
zhttpd_http_requests_total 1234

# HELP zhttpd_http_request_duration_ms HTTP request duration in milliseconds
# TYPE zhttpd_http_request_duration_ms histogram
zhttpd_http_request_duration_ms_bucket{le="1"} 500
zhttpd_http_request_duration_ms_bucket{le="5"} 1000
zhttpd_http_request_duration_ms_bucket{le="10"} 1100
...
zhttpd_http_request_duration_ms_sum 5234.567
zhttpd_http_request_duration_ms_count 1234
```

### Prometheus Scrape Configuration

```yaml
scrape_configs:
  - job_name: 'zhttpd'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
```

## Health Check Endpoint

When `enable_health_check: true`, a health check endpoint is available at `/health`.

### Response Format

```json
{
  "status": "healthy",
  "version": "0.1.2",
  "uptime_seconds": 3600,
  "components": {
    "http_server": "healthy",
    "lua_engine": "healthy",
    "file_cache": "healthy"
  }
}
```

### Status Values

| Status | HTTP Code | Description |
|--------|-----------|-------------|
| `healthy` | 200 | All components functioning normally |
| `degraded` | 200 | Some components experiencing issues but service is available |
| `unhealthy` | 503 | Service is not able to handle requests |

### Use Cases

- **Load Balancer Health Checks**: Configure your load balancer to check `/health`
- **Kubernetes Probes**: Use for liveness and readiness probes
- **Monitoring Alerts**: Trigger alerts on non-200 responses

## Request ID Propagation

When `enable_request_id: true`, each HTTP request gets a unique `X-Request-ID` header.

### Behavior

1. If the incoming request has an `X-Request-ID` header, it's propagated to the response
2. If no `X-Request-ID` is present, a new UUID-like ID is generated
3. The ID is added to the response headers

### ID Format

```
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Example: `67c8a1f2-3b4d-0001-8f2a-1234567890ab`

Components:
- First 8 chars: Timestamp (seconds) in hex
- Next 4 chars: Microseconds in hex
- Next 4 chars: Thread counter in hex
- Last 12 chars: Random component

### Use in Distributed Tracing

Include the `X-Request-ID` in downstream service calls:

```bash
# Initial request
curl -i http://localhost:8080/api/users

# Response includes:
# X-Request-ID: 67c8a1f2-3b4d-0001-8f2a-1234567890ab

# Use same ID in downstream calls
curl -H "X-Request-ID: 67c8a1f2-3b4d-0001-8f2a-1234567890ab" http://service-b/api/data
```

## Structured JSON Logging

When `log_format: "json"`, logs are output in JSON format for machine parsing.

### JSON Log Format

```json
{"timestamp":"2025-11-27 09:00:00.123456","level":"info","message":"Request processed"}
```

With request ID:
```json
{"timestamp":"2025-11-27 09:00:00.123456","level":"info","request_id":"abc123","message":"Request processed"}
```

### Fields

| Field | Description |
|-------|-------------|
| `timestamp` | ISO 8601 format with microsecond precision |
| `level` | Log level: debug, info, warn, error |
| `message` | Log message content |
| `request_id` | (Optional) Request ID if available |

### Log Aggregation Integration

JSON logs work well with log aggregation systems:

- **ELK Stack**: Parse with Logstash JSON filter
- **Fluentd**: Use JSON parser
- **CloudWatch**: Automatic JSON field extraction
- **Datadog**: JSON log parsing

Example Fluentd configuration:

```
<source>
  @type tail
  path /var/log/zhttpd.log
  pos_file /var/log/td-agent/zhttpd.pos
  tag zhttpd
  <parse>
    @type json
  </parse>
</source>
```

## Best Practices

### Production Configuration

```yaml
# Observability settings for production
enable_metrics: true
enable_health_check: true
enable_request_id: true
log_format: "json"
log_level: "info"
log_file: "/var/log/zhttpd/application.log"
access_log_file: "/var/log/zhttpd/access.log"
```

### Kubernetes Deployment

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: zhttpd
    image: zhttpd:latest
    ports:
    - containerPort: 8080
    livenessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
```

### Prometheus ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: zhttpd
spec:
  selector:
    matchLabels:
      app: zhttpd
  endpoints:
  - port: web
    path: /metrics
    interval: 30s
```

## Performance Considerations

- Metrics collection uses atomic operations for thread-safety with minimal overhead
- Health checks are lightweight and don't perform expensive operations
- Request ID generation is efficient using timestamp-based UUIDs
- JSON logging has slightly higher overhead than text format (~10% additional CPU)

## Troubleshooting

### Metrics Endpoint Returns 503

Check that `enable_metrics: true` is set in configuration.

### Health Check Returns Unhealthy

Check the `components` object in the response to identify which component is failing.

### Missing Request IDs

Ensure `enable_request_id: true` is set. Check that your proxy/load balancer isn't stripping the header.

### JSON Logs Not Parsing

Verify `log_format: "json"` is set and that the log file contains valid JSON lines.

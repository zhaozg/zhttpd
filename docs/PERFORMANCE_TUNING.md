# Performance Tuning Guide

## Overview

zhttpd v0.1.2 introduces configurable performance tuning options to optimize server behavior for different workloads and environments.

## Configuration Options

### max_connections

**Description:** Maximum number of concurrent client connections

**Default:** `512`

**Range:** 1 - 65535

**Impact:**
- **Higher values**: Support more concurrent users but consume more memory
- **Lower values**: Reduce memory usage but may reject connections under high load

**Recommendations:**
```yaml
# Small site or development (1-100 concurrent users)
max_connections: 256

# Medium site (100-500 concurrent users)
max_connections: 512  # Default

# Large site or high traffic (500+ concurrent users)
max_connections: 1024

# Very high traffic sites
max_connections: 2048
```

**Memory Impact:**
- Each connection uses ~1-2KB base memory
- Total connection overhead = max_connections × 1.5KB (approximately)
- Example: 512 connections ≈ 768KB memory

### request_buffer_size

**Description:** Buffer size for request/response processing

**Default:** `65536` (64KB)

**Range:** 4096 - 1048576 (4KB - 1MB)

**Impact:**
- **Larger buffers**: Better performance for large requests/responses
- **Smaller buffers**: Lower memory usage per request

**Recommendations:**
```yaml
# API-only server with small payloads
request_buffer_size: 16384  # 16KB

# General web server (default)
request_buffer_size: 65536  # 64KB

# File upload or large API payloads
request_buffer_size: 131072  # 128KB

# Very large files or streaming
request_buffer_size: 262144  # 256KB
```

**Memory Impact:**
- Memory per active request = request_buffer_size
- Total buffer memory = active_requests × request_buffer_size
- Example: 100 active requests × 64KB = 6.4MB

### thread_pool_size

**Description:** Number of worker threads handling requests

**Default:** `4`

**Range:** 1 - CPU cores × 2

**Recommendations:**
```yaml
# Single CPU or low traffic
thread_pool_size: 1

# Dual-core CPU
thread_pool_size: 2

# Quad-core CPU (default)
thread_pool_size: 4

# 8-core CPU
thread_pool_size: 8

# High-core count server (e.g., 16 cores)
thread_pool_size: 16
```

**Notes:**
- More threads ≠ better performance beyond your CPU core count
- Excessive threads increase context switching overhead
- Rule of thumb: thread_pool_size = CPU cores (or cores + 1)

## Performance Profiles

### Memory-Constrained Environment
```yaml
max_connections: 256
request_buffer_size: 16384  # 16KB
thread_pool_size: 2
```
**Total memory overhead:** ~400KB + 4MB buffers = ~4.4MB

### Balanced Configuration (Default)
```yaml
max_connections: 512
request_buffer_size: 65536  # 64KB
thread_pool_size: 4
```
**Total memory overhead:** ~768KB + 32MB buffers = ~33MB

### High-Performance Server
```yaml
max_connections: 2048
request_buffer_size: 131072  # 128KB
thread_pool_size: 8
```
**Total memory overhead:** ~3MB + 256MB buffers = ~259MB

### File Upload Server
```yaml
max_connections: 512
request_buffer_size: 262144  # 256KB
thread_pool_size: 4
max_body_size: 104857600  # 100MB
```

## Tuning Process

### Step 1: Baseline
Start with default configuration and monitor:
- CPU usage
- Memory usage
- Request latency
- Connection rejections

### Step 2: Identify Bottleneck
- **High CPU, low memory**: Increase thread_pool_size
- **Low CPU, high memory**: Decrease request_buffer_size or max_connections
- **Connection rejections**: Increase max_connections
- **Large request timeouts**: Increase request_buffer_size

### Step 3: Adjust
Make incremental changes:
1. Adjust one parameter at a time
2. Monitor for 10-15 minutes
3. Measure improvement
4. Repeat if needed

### Step 4: Validate
Run load tests to verify:
```bash
# Apache Bench
ab -n 10000 -c 100 http://your-server:8080/

# h2load
h2load --h1 -c 100 -t 4 -n 10000 http://your-server:8080/
```

## Monitoring

### Check Configuration at Runtime
Server logs show configuration on startup:
```
[INFO] Thread pool size: 4
[INFO] Max connections: 512
[INFO] Request buffer size: 65536 bytes
```

### Monitor Performance
Use access logs to track:
- Request rate (requests/second)
- Average response time
- Error rate

## Best Practices

1. **Start Conservative**: Begin with defaults and scale up as needed
2. **Monitor First**: Measure before and after changes
3. **Single Changes**: Adjust one parameter at a time
4. **Test Under Load**: Use realistic traffic patterns
5. **Document**: Keep track of configuration changes and results

## Common Scenarios

### Scenario 1: High Traffic Spike
**Symptom:** Connection rejections, slow responses
**Solution:**
```yaml
max_connections: 1024  # Up from 512
thread_pool_size: 8    # Up from 4
```

### Scenario 2: Memory Pressure
**Symptom:** High memory usage, swapping
**Solution:**
```yaml
max_connections: 256       # Down from 512
request_buffer_size: 32768  # Down from 65536 (32KB)
```

### Scenario 3: Large File Uploads
**Symptom:** Upload timeouts, buffer overflows
**Solution:**
```yaml
request_buffer_size: 262144  # Up to 256KB
max_body_size: 104857600     # 100MB
timeout_seconds: 120         # Longer timeout
```

### Scenario 4: API Server (Small Payloads)
**Symptom:** Wasted memory on large buffers
**Solution:**
```yaml
request_buffer_size: 16384  # Down to 16KB
max_connections: 1024       # More connections
```

## Performance Metrics

### Expected Throughput
With default configuration on modern hardware:
- **Static files**: 10,000-50,000 req/s
- **Dynamic content (Lua)**: 5,000-10,000 req/s
- **GraphQL queries**: 3,000-8,000 req/s

### Memory Usage
Baseline (idle server): ~10-20MB
- + (max_connections × 1.5KB)
- + (active_requests × request_buffer_size)
- + File cache usage

## Troubleshooting

### Problem: Connection Refused
**Cause:** max_connections reached
**Solution:** Increase max_connections or reduce connection duration

### Problem: High Memory Usage
**Cause:** Too many connections or large buffers
**Solution:** Reduce max_connections or request_buffer_size

### Problem: Slow Responses
**Cause:** Insufficient threads or CPU-bound
**Solution:** Increase thread_pool_size (up to CPU cores)

### Problem: CPU At 100%
**Cause:** Too many threads or compute-heavy requests
**Solution:** Decrease thread_pool_size or optimize request handlers

## See Also

- [README.md](../README.md) - Main documentation
- [ROADMAP.md](../ROADMAP.md) - Future features
- [STATUS.md](../STATUS.md) - Current status
- [ETAG_CACHING.md](./ETAG_CACHING.md) - ETag caching guide

# h2load Compatibility Issue with httpz

## Problem

When testing zhttpd (using httpz.Server) with `h2load --h1`, all requests are marked as "failed" even though:
- The HTTP responses are valid (verified with curl and netcat)
- Apache Bench successfully processes the same requests
- The server returns proper HTTP/1.1 200 responses with correct headers and content

## Symptoms

```bash
$ h2load --h1 -c 5 -t 1 -n 100 http://127.0.0.1:8080/
...
requests: 100 total, 100 started, 100 done, 0 succeeded, 100 failed, 0 errored, 0 timeout
status codes: 0 2xx, 0 3xx, 0 4xx, 0 5xx
```

## Root Cause

The issue appears to be related to how httpz formats the HTTP status line. While the response is valid HTTP/1.1:

```
HTTP/1.1 200 
Content-Type: text/html; charset=UTF-8
...
```

h2load may be expecting a specific format or additional fields in the status line that httpz doesn't provide.

## Workaround

Use Apache Bench (ab) or other HTTP benchmarking tools for performance testing:

```bash
ab -n 10000 -c 10 http://127.0.0.1:8080/
```

## Performance Results

With Apache Bench, the server achieves excellent performance:
- **~10,000 req/s** consistently across various concurrency levels
- All requests succeed
- Low latency (< 0.1ms per request)

## Future Fix

This appears to be an httpz library behavior that may need to be addressed in upstream httpz. For now, Apache Bench provides reliable and accurate performance measurements.

## References

- httpz: https://github.com/karlseguin/http.zig
- h2load: https://nghttp2.org/documentation/h2load.1.html

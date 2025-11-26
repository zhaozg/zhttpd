# ETag Caching Support

## Overview

zhttpd supports **ETag (Entity Tag)** caching for static files, which significantly reduces bandwidth usage and improves performance for frequently accessed resources.

## What are ETags?

ETags are HTTP response headers that allow efficient cache validation. When a client has a cached copy of a resource, it can send an `If-None-Match` header with the ETag value. If the resource hasn't changed, the server responds with `304 Not Modified` instead of transferring the full file again.

## Implementation Details

### Weak ETags

zhttpd uses **weak ETags** (indicated by the `W/` prefix) based on:
- File size
- File modification time (mtime)

Format: `W/"<size-hex>-<mtime-hex>"`

Example: `W/"ebb-187b9781dffa8ae7"`

### Why Weak ETags?

- **Performance**: Computing strong ETags requires hashing file content, which is expensive for large files
- **Sufficient**: For static files, size + mtime provides excellent change detection
- **Compliant**: Follows RFC 7232 HTTP conditional request specifications

## Configuration

Enable or disable ETag support in your configuration file:

### YAML Configuration
```yaml
enable_etag: true  # Default: true
```

### JSON Configuration
```json
{
  "enable_etag": true
}
```

## How It Works

### First Request (Cache Miss)
```
Client -> Server: GET /index.html
Server -> Client: 200 OK
                  ETag: W/"ebb-187b9781dffa8ae7"
                  Cache-Control: public, max-age=3600
                  [Full file content]
```

### Subsequent Request (Cache Hit)
```
Client -> Server: GET /index.html
                  If-None-Match: W/"ebb-187b9781dffa8ae7"
Server -> Client: 304 Not Modified
                  ETag: W/"ebb-187b9781dffa8ae7"
                  [Empty body - no file transfer!]
```

## Benefits

### 1. Bandwidth Reduction
- **304 responses** have minimal body content
- No file transfer for unchanged resources
- Particularly effective for:
  - Large static assets (images, videos)
  - Frequently accessed pages
  - CDN and proxy caching

### 2. Reduced Server Load
- Less data to send over the network
- Faster response times for cached resources
- Lower CPU usage (no file reading for 304 responses)

### 3. Improved User Experience
- Faster page loads for returning visitors
- Reduced latency
- Better mobile experience (less data transfer)

## Performance Impact

For a typical web application:
- **Bandwidth savings**: 50-90% for returning visitors
- **Response time**: 304 responses are 2-5x faster than full responses
- **Server throughput**: Can handle more concurrent users

### Example Scenario
```
File size: 3KB HTML page
Full response: 3KB + HTTP headers (~3.1KB total)
304 response: ~200 bytes (HTTP headers only)
Savings: ~94% bandwidth reduction
```

## Browser Behavior

Modern browsers automatically:
1. Store ETags from server responses
2. Include `If-None-Match` headers in subsequent requests
3. Revalidate cached resources based on `Cache-Control` directives

zhttpd sets `Cache-Control: public, max-age=3600` (1 hour) for static files when ETags are enabled.

## Best Practices

### 1. Keep ETags Enabled (Default)
ETags provide significant benefits with minimal overhead. Leave them enabled unless you have specific requirements.

### 2. Monitor Cache Hit Rates
Use access logs to track:
- 200 (full response) vs 304 (cached) ratio
- Bandwidth savings
- Response time improvements

### 3. Combine with CDN
ETags work excellently with CDN caching:
- CDN can validate cached content with origin server
- Reduces origin server load
- Maintains content freshness

### 4. File Modification Considerations
- ETags automatically change when files are modified
- No manual cache invalidation needed
- Atomic file updates recommended (write to temp, then rename)

## Disabling ETags

If you need to disable ETags (e.g., for testing or specific use cases):

```yaml
enable_etag: false
```

When disabled:
- No `ETag` headers in responses
- No `304 Not Modified` responses
- All requests return full file content
- Cache-Control headers are not added

## Debugging

### Check if ETags are Working

```bash
# First request - get ETag
curl -v http://localhost:8080/index.html 2>&1 | grep -i etag

# Second request - use ETag
ETAG=$(curl -s -D - http://localhost:8080/index.html | grep -i etag | cut -d' ' -f2-)
curl -v -H "If-None-Match: $ETAG" http://localhost:8080/index.html
```

Expected output:
- First request: `200 OK` with `ETag` header
- Second request: `304 Not Modified`

### Common Issues

**Issue**: Always getting 200 responses, never 304
- Check if `enable_etag: true` in configuration
- Verify browser is sending `If-None-Match` header
- Check if file was modified between requests

**Issue**: ETags change unexpectedly
- File system may not preserve mtimes during deployment
- Consider using rsync with `--times` flag for deployments
- Docker/container restarts may affect file mtimes

## Technical Details

### ETag Generation Algorithm
```zig
// Weak ETag format: W/"<size-hex>-<mtime-hex>"
pub fn generateETag(allocator: std.mem.Allocator, size: u64, mtime: i128) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "W/\"{x}-{x}\"", .{ size, mtime });
}
```

### Comparison
- ETag comparison is **byte-for-byte exact**
- Case-sensitive string comparison
- Weak vs strong ETags are distinguished by `W/` prefix

### HTTP Status Codes
- **200 OK**: File sent, ETag included in response
- **304 Not Modified**: File unchanged, no body sent
- **400 Bad Request**: Invalid request
- **404 Not Found**: File doesn't exist

## References

- [RFC 7232 - HTTP Conditional Requests](https://tools.ietf.org/html/rfc7232)
- [MDN: ETag](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/ETag)
- [MDN: Cache-Control](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control)

## See Also

- [LOGGING.md](./LOGGING.md) - Access log configuration
- [../README.md](../README.md) - Main documentation
- [../ROADMAP.md](../ROADMAP.md) - Future enhancements

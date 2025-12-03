#!/bin/bash

# Performance benchmark script for Lua handlers
# Compares performance of handlers with and without database access

set -e

echo "=== Lua Handler Performance Benchmark ==="
echo ""

# Configuration
HOST="127.0.0.1"
PORT="8080"
REQUESTS=10000
CONCURRENCY=50

# Check if server is running
if ! curl -s "http://${HOST}:${PORT}/health" > /dev/null 2>&1; then
    echo "Error: Server is not running at http://${HOST}:${PORT}"
    echo "Please start the server first with: zig-out/bin/zhttpd"
    exit 1
fi

echo "Server is running. Starting benchmarks..."
echo ""

# Benchmark without database
echo "=== Test 1: Handler WITHOUT database access ==="
echo "Endpoint: /api/perf_test_no_db"
echo "Requests: ${REQUESTS}, Concurrency: ${CONCURRENCY}"
echo ""

ab -n ${REQUESTS} -c ${CONCURRENCY} -q "http://${HOST}:${PORT}/api/perf_test_no_db" 2>&1 | \
  grep -E "Requests per second|Time per request|Transfer rate|Failed requests" || true

echo ""

# Benchmark with database (if enabled)
echo "=== Test 2: Handler WITH database access ==="
echo "Endpoint: /api/perf_test_with_db"
echo "Requests: ${REQUESTS}, Concurrency: ${CONCURRENCY}"
echo ""

ab -n ${REQUESTS} -c ${CONCURRENCY} -q "http://${HOST}:${PORT}/api/perf_test_with_db" 2>&1 | \
  grep -E "Requests per second|Time per request|Transfer rate|Failed requests" || true

echo ""
echo "=== Benchmark Complete ==="
echo ""
echo "Performance Analysis:"
echo "- Handlers without database should have minimal overhead"
echo "- Handlers with database should have similar performance (context:db() is now optimized)"
echo "- If database is not configured, the second test will return an error response but still measures overhead"

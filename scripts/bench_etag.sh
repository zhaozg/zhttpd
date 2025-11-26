#!/bin/bash
# Benchmark script to measure ETag performance improvements

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==================================================================="
echo "ETag Performance Benchmark"
echo "==================================================================="
echo ""

# Build the server in ReleaseFast mode
echo "Building server in ReleaseFast mode..."
zig build -Doptimize=ReleaseFast > /dev/null 2>&1

# Start server
echo "Starting server..."
./zig-out/bin/zhttpd > /tmp/bench_server.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Server started with PID: $SERVER_PID"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -f /tmp/bench_server.log
}

trap cleanup EXIT

# Function to benchmark
benchmark_requests() {
    local name=$1
    local requests=$2
    local etag=$3
    
    echo "Running: $name"
    
    local start=$(date +%s%N)
    for i in $(seq 1 $requests); do
        if [ -n "$etag" ]; then
            curl -s -H "If-None-Match: $etag" http://127.0.0.1:8080/ > /dev/null
        else
            curl -s http://127.0.0.1:8080/ > /dev/null
        fi
    done
    local end=$(date +%s%N)
    
    local duration=$(( ($end - $start) / 1000000 )) # Convert to milliseconds
    local rps=$(( $requests * 1000 / $duration ))
    
    echo "  Requests: $requests"
    echo "  Duration: ${duration}ms"
    echo "  Req/sec:  $rps"
    echo ""
}

# Get ETag from first request
echo "Getting ETag from initial request..."
ETAG=$(curl -s -D - http://127.0.0.1:8080/ 2>&1 | grep -i "etag:" | awk '{print $2}' | tr -d '\r\n')
echo "ETag: $ETAG"
echo ""

# Benchmark without ETag (full response)
benchmark_requests "Benchmark 1: Full responses (no caching)" 100 ""

# Benchmark with ETag (304 responses)
benchmark_requests "Benchmark 2: Cached responses (with ETag)" 100 "$ETAG"

echo "==================================================================="
echo "Summary:"
echo "  ETag support significantly reduces bandwidth usage for"
echo "  unchanged files by returning 304 Not Modified responses"
echo "  instead of transferring the full file content."
echo "==================================================================="

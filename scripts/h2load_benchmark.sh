#!/bin/bash

# h2load benchmark script for zhttpd server
# Tests HTTP/1.1 performance with various concurrency levels

set -e

echo "=========================================="
echo "zhttpd Performance Benchmark (h2load --h1)"
echo "=========================================="
echo ""

# Server configuration
SERVER_HOST="127.0.0.1"
SERVER_PORT="8080"
SERVER_URL="http://${SERVER_HOST}:${SERVER_PORT}/"

# Test configurations
DURATION=10  # seconds
WARMUP=2     # seconds

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if server is running
check_server() {
    echo -e "${BLUE}Checking if server is running...${NC}"
    if curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL" | grep -q "200\|404"; then
        echo -e "${GREEN}✓ Server is running${NC}"
        return 0
    else
        echo -e "${YELLOW}✗ Server is not responding on ${SERVER_URL}${NC}"
        echo "Please start the server first: ./zig-out/bin/zhttpd"
        exit 1
    fi
}

# Run benchmark with h2load
run_h2load_test() {
    local clients=$1
    local threads=$2
    local requests=$3
    local description=$4
    
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Test: ${description}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Clients: $clients, Threads: $threads, Total Requests: $requests"
    echo ""
    
    # Run h2load with HTTP/1.1
    h2load --h1 \
        -c "$clients" \
        -t "$threads" \
        -n "$requests" \
        -m 10 \
        --warm-up-time="$WARMUP" \
        "$SERVER_URL"
    
    echo ""
}

# Main benchmark suite
main() {
    echo "Build: ReleaseFast"
    echo "Tool: h2load (HTTP/1.1)"
    echo "Duration: ${DURATION}s per test"
    echo "Warmup: ${WARMUP}s"
    echo ""
    
    check_server
    
    echo ""
    echo -e "${YELLOW}Starting benchmark tests...${NC}"
    
    # Test 1: Low concurrency
    run_h2load_test 10 2 100000 "Low Concurrency (10 clients)"
    
    # Test 2: Medium concurrency
    run_h2load_test 50 4 500000 "Medium Concurrency (50 clients)"
    
    # Test 3: High concurrency
    run_h2load_test 100 8 1000000 "High Concurrency (100 clients)"
    
    # Test 4: Very high concurrency
    run_h2load_test 200 8 2000000 "Very High Concurrency (200 clients)"
    
    echo ""
    echo -e "${GREEN}=========================================="
    echo "Benchmark Complete!"
    echo -e "==========================================${NC}"
    echo ""
    echo "Note: Results may vary based on system resources and load."
    echo "For production estimates, run tests on similar hardware."
}

# Run the benchmark
main "$@"

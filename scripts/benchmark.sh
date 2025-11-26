#!/usr/bin/env bash
set -e

# Benchmark script for zhttpd using h2load

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== zhttpd Benchmark Script ===${NC}"

# Check if h2load is installed
if ! command -v h2load &> /dev/null; then
    echo -e "${RED}Error: h2load is not installed${NC}"
    echo "Install with: sudo apt-get install nghttp2-client"
    exit 1
fi

# Build the server in ReleaseFast mode
echo -e "\n${YELLOW}Building server in ReleaseFast mode...${NC}"
zig build -Doptimize=ReleaseFast

# Ensure example files exist
echo -e "\n${YELLOW}Setting up test files...${NC}"
mkdir -p examples/static
if [ ! -f "examples/static/index.html" ]; then
    echo "<html><head><title>Benchmark Test</title></head><body><h1>Hello from zhttpd!</h1><p>This is a test page for benchmarking.</p></body></html>" > examples/static/index.html
fi

# Create config file if it doesn't exist
if [ ! -f "config.json" ]; then
    cp config.example.json config.json
fi

# Start the server
echo -e "\n${YELLOW}Starting server...${NC}"
./zig-out/bin/zhttpd &
SERVER_PID=$!

# Wait for server to start
echo "Waiting for server to start (PID: $SERVER_PID)..."
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}Error: Server failed to start${NC}"
    exit 1
fi

echo -e "${GREEN}Server started successfully${NC}"

# Run benchmarks with different configurations
echo -e "\n${YELLOW}=== Running Benchmarks ===${NC}"

# Test 1: Simple GET request
echo -e "\n${GREEN}Test 1: Simple GET request (10,000 requests, 100 connections)${NC}"
h2load -n 10000 -c 100 -t 4 http://127.0.0.1:8080/ || true

# Test 2: Higher concurrency
echo -e "\n${GREEN}Test 2: Higher concurrency (50,000 requests, 500 connections)${NC}"
h2load -n 50000 -c 500 -t 8 http://127.0.0.1:8080/ || true

# Test 3: Keep-alive connections
echo -e "\n${GREEN}Test 3: Keep-alive (100,000 requests, 100 connections, 10 max concurrent streams)${NC}"
h2load -n 100000 -c 100 -t 4 -m 10 http://127.0.0.1:8080/ || true

# Stop the server
echo -e "\n${YELLOW}Stopping server...${NC}"
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo -e "\n${GREEN}=== Benchmark Complete ===${NC}"
echo "Results have been displayed above. Consider updating README.md with these results."

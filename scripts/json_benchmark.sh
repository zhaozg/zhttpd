#!/bin/bash
# JSON Performance Benchmark Script
# Compares zhttpd's built-in json module vs lua-cjson
#
# Usage: ./scripts/json_benchmark.sh
#
# Requirements:
# - zig 0.15.x
# - lua5.4 with lua-cjson installed

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================================================${NC}"
echo -e "${BLUE}              JSON Performance Benchmark: zhttpd json vs lua-cjson              ${NC}"
echo -e "${BLUE}=================================================================================${NC}"
echo ""

# Check if lua-cjson is available
if ! lua5.4 -e "require('cjson')" 2>/dev/null; then
    echo -e "${RED}Error: lua-cjson not installed. Install with: sudo apt-get install lua-cjson${NC}"
    exit 1
fi

# Run lua-cjson benchmark
echo -e "${GREEN}Running lua-cjson benchmark...${NC}"
echo ""
lua5.4 scripts/json_cjson_benchmark.lua

echo ""
echo -e "${GREEN}Note: zhttpd's json module performance can be tested by running the server${NC}"
echo -e "${GREEN}with ReleaseFast optimization and accessing /api/json_benchmark endpoint.${NC}"
echo ""
echo -e "${BLUE}Build with:${NC} zig build -Doptimize=ReleaseFast"
echo -e "${BLUE}Start server:${NC} ./zig-out/bin/zhttpd"
echo -e "${BLUE}Test endpoint:${NC} curl http://localhost:8080/api/json_benchmark"
echo ""
echo -e "${BLUE}=================================================================================${NC}"

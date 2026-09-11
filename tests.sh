#!/bin/sh
#
# tests.sh - Test all Lua example scripts via HTTP API
#
# This script starts the zhttpd server, runs tests against all Lua
# example scripts under /api/ endpoints, and reports results.
#
# Usage: sh ./tests.sh [server_binary]
#   server_binary - path to zhttpd binary (default: zig-out/bin/zhttpd)
#
# The script is POSIX sh compatible (works with dash, ash, bash, etc.).

set -u

# Configuration
SERVER_BIN="${1:-zig-out/bin/zhttpd}"
SERVER_PORT="${ZHTTPD_TEST_PORT:-8080}"
BASE_URL="http://127.0.0.1:${SERVER_PORT}"
TIMEOUT_SEC="${ZHTTPD_TEST_TIMEOUT:-10}"

# Authentication token used for protected /api/* endpoints.
# The default configuration enables the auth middleware, which delegates
# validation to examples/lua/auth.lua. That script accepts demo tokens of the
# form zhttpd_<user_id>_<role>.
AUTH_TOKEN="${ZHTTPD_TEST_TOKEN:-zhttpd_1_admin}"
AUTH_HEADER="Authorization: Bearer ${AUTH_TOKEN}"

# Colors (empty when not writing to a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
fi

# Test counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Cleanup
cleanup() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Print banner
printf '%b\n' "${CYAN}========================================${NC}"
printf '%b\n' "${CYAN}  zhttpd Lua Example Scripts Test Suite ${NC}"
printf '%b\n' "${CYAN}========================================${NC}"
printf '\n'

# Check server binary
if [ ! -f "$SERVER_BIN" ]; then
    printf '%b\n' "${RED}Error: Server binary not found: $SERVER_BIN${NC}"
    printf 'Build with: zig build\n'
    exit 1
fi

# Check tools
for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '%b\n' "${RED}Error: '$cmd' is required but not installed.${NC}"
        exit 1
    fi
done

# Start server
printf '%b\n' "${YELLOW}Starting server...${NC}"
"$SERVER_BIN" &
SERVER_PID=$!
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    printf '%b\n' "${RED}Error: Server failed to start${NC}"
    exit 1
fi
printf '%b\n' "${GREEN}Server started (PID: $SERVER_PID)${NC}"
printf '\n'

# ============================================
# Helper functions
# ============================================

# Run a test with custom validation
run_test() {
    name="$1"
    method="$2"
    path="$3"
    body="${4:-}"
    validator="${5:-}"

    TOTAL=$((TOTAL + 1))
    printf '%b' "  Testing ${CYAN}${name}${NC} ... "
    if [ "$method" = "GET" ]; then
        response=$(curl -s -m "$TIMEOUT_SEC" -H "$AUTH_HEADER" "${BASE_URL}${path}" 2>&1)
    else
        response=$(curl -s -m "$TIMEOUT_SEC" -X "$method" "${BASE_URL}${path}" \
            -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$body" 2>&1)
    fi

    if [ $? -ne 0 ]; then
        printf '%b\n' "${RED}FAILED (connection error)${NC}"
        printf '    Response: %s\n' "$response"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # Check for server-level error
    status=$(printf '%s' "$response" | jq -r '.status // ""' 2>/dev/null)
    if [ "$status" = "error" ]; then
        msg=$(printf '%s' "$response" | jq -r '.message // "unknown error"' 2>/dev/null)
        printf '%b\n' "${RED}FAILED (error: $msg)${NC}"
        printf '    Response: %s\n' "$response"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if [ -n "$validator" ]; then
        printf '%s' "$response" | jq -e "$validator" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            printf '%b\n' "${RED}FAILED (validation)${NC}"
            printf '    Response: %s\n' "$response"
            FAILED=$((FAILED + 1))
            return 1
        fi
    fi

    printf '%b\n' "${GREEN}PASSED${NC}"
    PASSED=$((PASSED + 1))
    return 0
}

# Run a test that expects non-JSON response (e.g., HTML, plain text)
run_raw_test() {
    name="$1"
    method="$2"
    path="$3"
    body="${4:-}"
    expected_content="${5:-}"

    TOTAL=$((TOTAL + 1))
    printf '%b' "  Testing ${CYAN}${name}${NC} ... "

    if [ "$method" = "GET" ]; then
        response=$(curl -s -m "$TIMEOUT_SEC" -H "$AUTH_HEADER" "${BASE_URL}${path}" 2>&1)
    else
        response=$(curl -s -m "$TIMEOUT_SEC" -X "$method" "${BASE_URL}${path}" \
            -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$body" 2>&1)
    fi

    if [ $? -ne 0 ]; then
        printf '%b\n' "${RED}FAILED (connection error)${NC}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if [ -n "$expected_content" ]; then
        printf '%s' "$response" | grep -q "$expected_content"
        if [ $? -ne 0 ]; then
            printf '%b\n' "${RED}FAILED (expected content not found)${NC}"
            FAILED=$((FAILED + 1))
            return 1
        fi
    fi

    printf '%b\n' "${GREEN}PASSED${NC}"
    PASSED=$((PASSED + 1))
    return 0
}

skip_test() {
    name="$1"
    reason="$2"
    TOTAL=$((TOTAL + 1))
    SKIPPED=$((SKIPPED + 1))
    printf '%b\n' "  Testing ${CYAN}${name}${NC} ... ${YELLOW}SKIPPED${NC} (${reason})"
}

# ============================================
# Tests
# ============================================

printf '%b\n' "${YELLOW}Running tests...${NC}"
printf '\n'

# Basic handler
printf '%b\n' "${CYAN}[Basic Handler]${NC}"
run_test "test.lua" "GET" "/api/test" "" '.status == "success"'
run_test "test.lua - message" "GET" "/api/test" "" '.message == "Hello from Lua!"'
run_test "test.lua - request info" "GET" "/api/test" "" \
    '.request_info.method == "GET" and .request_info.path == "/api/test"'
printf '\n'

# LPeg tests
printf '%b\n' "${CYAN}[LPeg Pattern Matching]${NC}"
run_test "lpeg_test.lua" "GET" "/api/lpeg_test" "" '.status == "success"'
run_test "lpeg_test.lua - message" "GET" "/api/lpeg_test" "" '.message == "LPeg module is working!"'
run_test "lpeg_test.lua - lpeg type" "GET" "/api/lpeg_test" "" '.lpeg_type == "table"'
run_test "lpeg_test.lua - functions" "GET" "/api/lpeg_test" "" \
    '.lpeg_functions.P == "function" and .lpeg_functions.match == "function"'
run_test "lpeg_test.lua - basic match" "GET" "/api/lpeg_test" "" '.tests.basic_match.result == 6'
run_test "lpeg_test.lua - capture" "GET" "/api/lpeg_test" "" '.tests.capture.captured == "hello"'
run_test "lpeg_test.lua - number" "GET" "/api/lpeg_test" "" '.tests.number.captured == "-123.456"'
printf '\n'

# LPeg advanced
printf '%b\n' "${CYAN}[LPeg Advanced]${NC}"
run_test "lpeg_advanced.lua" "GET" "/api/lpeg_advanced" "" '.status == "success"'
run_test "lpeg_advanced.lua - message" "GET" "/api/lpeg_advanced" "" \
    '.message == "Advanced LPeg examples"'
run_test "lpeg_advanced.lua - headers" "GET" "/api/lpeg_advanced" "" \
    '.examples.headers.parsed[0][0] == "Content-Type"'
run_test "lpeg_advanced.lua - CSV" "GET" "/api/lpeg_advanced" "" \
    '.examples.csv.parsed[0] == "John"'
run_test "lpeg_advanced.lua - URL params" "GET" "/api/lpeg_advanced" "" \
    '.examples.url_params.extracted.id == "42"'
run_test "lpeg_advanced.lua - color" "GET" "/api/lpeg_advanced" "" \
    '.examples.color.rgb[1] == "57"'
printf '\n'

# JSON tests
printf '%b\n' "${CYAN}[JSON Module]${NC}"
run_test "json_test.lua" "GET" "/api/json_test" "" '.status == "success"'
run_test "json_test.lua - json available" "GET" "/api/json_test" "" '.json_available == true'
run_test "json_test.lua - encode/decode" "GET" "/api/json_test" "" \
    '.decoded_status == "ok" and .decoded_count == 42'
run_test "json_test.lua - special chars" "GET" "/api/json_test" "" '.special_chars_valid == true'
run_test "json_test.lua - deep nesting" "GET" "/api/json_test" "" '.deep_valid == true'
run_test "json_test.lua - request info" "GET" "/api/json_test" "" \
    '.request_tests.method == "GET" and .request_tests.has_context == true'
printf '\n'

# JSON benchmark (iteration count tuned to fit the sandbox instruction limit)
printf '%b\n' "${CYAN}[JSON Benchmark]${NC}"
run_test "json_benchmark.lua" "GET" "/api/json_benchmark" "" '.status == "success"'
printf '\n'
printf '\n'

# Users API (in-memory, no DB needed)
printf '%b\n' "${CYAN}[Users API]${NC}"
run_test "users.lua - GET" "GET" "/api/users" "" '.users != null'
run_test "users.lua - POST" "POST" "/api/users" '{"name":"TestUser"}' \
    '.name == "TestUser"'
printf '\n'

# Todo API (in-memory, no DB needed)
printf '%b\n' "${CYAN}[Todo API]${NC}"
run_test "todo.lua - GET" "GET" "/api/todo" "" '.status == "success"'
run_test "todo.lua - POST" "POST" "/api/todo" '{"title":"Test todo"}' \
    '.status == "success"'
printf '\n'

# Chunk example (returns non-JSON responses)
printf '%b\n' "${CYAN}[Chunked Response]${NC}"
run_raw_test "chunk_example.lua - simple" "GET" "/api/chunk_example/simple" "" \
    "Chunk 1"
run_raw_test "chunk_example.lua - html" "GET" "/api/chunk_example/html" "" \
    "DOCTYPE"
printf '\n'

# Performance test (no DB)
printf '%b\n' "${CYAN}[Performance Test (No DB)]${NC}"
run_test "perf_test_no_db.lua" "GET" "/api/perf_test_no_db" "" '.status == "success"'
printf '\n'

# Session (enable_session is on by default)
printf '%b\n' "${CYAN}[Session API]${NC}"
run_raw_test "session.lua - login page" "GET" "/api/session" "" "Login"
run_raw_test "session.lua - login" "POST" "/api/session" '{"username":"alice"}' "Welcome, alice"
printf '\n'
printf '\n'

# Auth middleware (enable_auth is on by default; auth.lua validates tokens)
printf '%b\n' "${CYAN}[Auth API]${NC}"
run_test "auth.lua - valid token" "GET" "/api/test" "" '.status == "success"'
printf '\n'
printf '\n'

# Database tests
printf '%b\n' "${CYAN}[Database Tests]${NC}"
db_check=$(curl -s -m 3 -H "$AUTH_HEADER" "${BASE_URL}/api/db_test" 2>/dev/null || printf '')
db_avail=$(printf '%s' "$db_check" | jq -r '.db_available // false' 2>/dev/null)

if [ "$db_avail" = "true" ]; then
    # Initialize the schema required by the database examples. The default
    # configuration uses an in-memory SQLite database, so tables must be
    # created before the read endpoints are exercised. db_test.lua creates
    # the users/sessions tables and seeds demo users (id 1 = admin).
    curl -s -m "$TIMEOUT_SEC" -X POST "${BASE_URL}/api/db_test/init" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true

    run_test "db_test.lua" "GET" "/api/db_test" "" '.status == "success"'
    run_test "users_db.lua - GET" "GET" "/api/users_db" "" '.status == "success"'
    run_test "users_db.lua - POST" "POST" "/api/users_db" \
        '{"name":"DbUser","email":"dbuser@example.com"}' \
        '.status == "success"'
    # auth_db.lua validates tokens of the form zhttpd_<user_id>_<role>.
    # User id 1 (admin) is seeded by db_test.lua's init endpoint.
    run_test "auth_db.lua" "POST" "/api/auth_db" \
        '{"token":"zhttpd_1_admin","type":"jwt"}' \
        '.authenticated == true'
    run_test "db_prepared_statements.lua - init" "POST" \
        "/api/db_prepared_statements/init" '{}' '.status == "success"'
    run_test "db_prepared_statements.lua - list" "GET" \
        "/api/db_prepared_statements/users" "" '.status == "success"'
    run_test "perf_test_with_db.lua" "GET" "/api/perf_test_with_db" "" \
        '.status == "success"'
else
    skip_test "db_test.lua" "database not configured"
    skip_test "users_db.lua" "database not configured"
    skip_test "auth_db.lua" "database not configured"
    skip_test "db_prepared_statements.lua" "database not configured"
    skip_test "perf_test_with_db.lua" "database not configured"
fi
# WebSocket
printf '%b\n' "${CYAN}[WebSocket]${NC}"
skip_test "websocket.lua" "upgrade disabled pending httpz Zig 0.16 API migration"
printf '\n'

# ============================================
# Summary
# ============================================
printf '%b\n' "${CYAN}========================================${NC}"
printf '%b\n' "${CYAN}  Test Summary${NC}"
printf '%b\n' "${CYAN}========================================${NC}"
printf '  Total:   %s\n' "$TOTAL"
printf '%b\n' "  Passed:  ${GREEN}${PASSED}${NC}"
printf '%b\n' "  Failed:  ${RED}${FAILED}${NC}"
printf '%b\n' "  Skipped: ${YELLOW}${SKIPPED}${NC}"
printf '\n'

if [ "$FAILED" -gt 0 ]; then
    printf '%b\n' "${RED}Some tests FAILED!${NC}"
    exit 1
elif [ "$PASSED" -eq "$TOTAL" ]; then
    printf '%b\n' "${GREEN}All tests PASSED!${NC}"
    exit 0
else
    printf '%b\n' "${YELLOW}All executed tests passed (${SKIPPED} skipped)${NC}"
    exit 0
fi

#!/usr/bin/env lua5.4
-- Standalone JSON Benchmark Script
-- Compares lua-cjson (https://github.com/mpx/lua-cjson) performance
-- Run: lua5.4 scripts/json_cjson_benchmark.lua

local cjson = require("cjson")

-- Benchmark configuration
local iterations = 100000

-- Test data: Simple object
local simple_data = {
    name = "test",
    value = 123,
    active = true
}

-- Test data: Complex nested object
local complex_data = {
    users = {
        {id = 1, name = "Alice", email = "alice@example.com", roles = {"admin", "user"}},
        {id = 2, name = "Bob", email = "bob@example.com", roles = {"user"}},
        {id = 3, name = "Charlie", email = "charlie@example.com", roles = {"guest"}}
    },
    metadata = {
        version = "1.0.0",
        timestamp = 1234567890,
        settings = {
            debug = false,
            cache = true,
            timeout = 30
        }
    },
    tags = {"performance", "benchmark", "json"},
    count = 42,
    enabled = true
}

-- Pre-encoded JSON strings for decode benchmarks
local simple_json = '{"name":"test","value":123,"active":true}'
local complex_json = '{"users":[{"id":1,"name":"Alice","email":"alice@example.com","roles":["admin","user"]},{"id":2,"name":"Bob","email":"bob@example.com","roles":["user"]},{"id":3,"name":"Charlie","email":"charlie@example.com","roles":["guest"]}],"metadata":{"version":"1.0.0","timestamp":1234567890,"settings":{"debug":false,"cache":true,"timeout":30}},"tags":["performance","benchmark","json"],"count":42,"enabled":true}'

print("================================================================================")
print("                          lua-cjson Benchmark Results                           ")
print("================================================================================")
print(string.format("Library: lua-cjson (https://github.com/mpx/lua-cjson)"))
print(string.format("Iterations: %d", iterations))
print("")

-- Benchmark: Simple encode
local start_time = os.clock()
for i = 1, iterations do
    cjson.encode(simple_data)
end
local simple_encode_time = os.clock() - start_time
local simple_encode_ops = iterations / simple_encode_time
print(string.format("Simple Encode:  %8.2f ms | %12.0f ops/sec", simple_encode_time * 1000, simple_encode_ops))

-- Benchmark: Complex encode
start_time = os.clock()
for i = 1, iterations do
    cjson.encode(complex_data)
end
local complex_encode_time = os.clock() - start_time
local complex_encode_ops = iterations / complex_encode_time
print(string.format("Complex Encode: %8.2f ms | %12.0f ops/sec", complex_encode_time * 1000, complex_encode_ops))

-- Benchmark: Simple decode
start_time = os.clock()
for i = 1, iterations do
    cjson.decode(simple_json)
end
local simple_decode_time = os.clock() - start_time
local simple_decode_ops = iterations / simple_decode_time
print(string.format("Simple Decode:  %8.2f ms | %12.0f ops/sec", simple_decode_time * 1000, simple_decode_ops))

-- Benchmark: Complex decode
start_time = os.clock()
for i = 1, iterations do
    cjson.decode(complex_json)
end
local complex_decode_time = os.clock() - start_time
local complex_decode_ops = iterations / complex_decode_time
print(string.format("Complex Decode: %8.2f ms | %12.0f ops/sec", complex_decode_time * 1000, complex_decode_ops))

print("")
print("--------------------------------------------------------------------------------")
local total_time = simple_encode_time + complex_encode_time + simple_decode_time + complex_decode_time
print(string.format("Total time: %.2f ms", total_time * 1000))
print("================================================================================")

-- Output in machine-readable format for comparison
print("")
print("=== Machine Readable Results (ops/sec) ===")
print(string.format("CJSON_SIMPLE_ENCODE=%.0f", simple_encode_ops))
print(string.format("CJSON_COMPLEX_ENCODE=%.0f", complex_encode_ops))
print(string.format("CJSON_SIMPLE_DECODE=%.0f", simple_decode_ops))
print(string.format("CJSON_COMPLEX_DECODE=%.0f", complex_decode_ops))

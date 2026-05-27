-- JSON Benchmark Script for zhttpd
-- This script benchmarks the built-in json module (lua-cjson)
--
-- Handler signature: function handle(request, response, context)

function handle(request, response, context)
    -- Benchmark configuration (same as lua-cjson benchmark for fair comparison)
    local iterations = 100000
    local json = require('json')

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

    -- Benchmark: Simple encode
    local start_time = os.clock()
    for i = 1, iterations do
        json.encode(simple_data)
    end
    local simple_encode_time = os.clock() - start_time

    -- Benchmark: Complex encode
    start_time = os.clock()
    for i = 1, iterations do
        json.encode(complex_data)
    end
    local complex_encode_time = os.clock() - start_time

    -- Benchmark: Simple decode
    start_time = os.clock()
    for i = 1, iterations do
        json.decode(simple_json)
    end
    local simple_decode_time = os.clock() - start_time

    -- Benchmark: Complex decode
    start_time = os.clock()
    for i = 1, iterations do
        json.decode(complex_json)
    end
    local complex_decode_time = os.clock() - start_time

    -- Calculate ops/sec
    local simple_encode_ops = iterations / simple_encode_time
    local complex_encode_ops = iterations / complex_encode_time
    local simple_decode_ops = iterations / simple_decode_time
    local complex_decode_ops = iterations / complex_decode_time

    return {
        status = "success",
        library = "zhttpd json (lua-cjson)",
        iterations = iterations,
        results = {
            simple_encode = {
                time_ms = simple_encode_time * 1000,
                ops_per_sec = simple_encode_ops
            },
            complex_encode = {
                time_ms = complex_encode_time * 1000,
                ops_per_sec = complex_encode_ops
            },
            simple_decode = {
                time_ms = simple_decode_time * 1000,
                ops_per_sec = simple_decode_ops
            },
            complex_decode = {
                time_ms = complex_decode_time * 1000,
                ops_per_sec = complex_decode_ops
            }
        }
    }
end

return {
    handle = handle
}

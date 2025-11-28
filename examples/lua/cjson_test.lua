-- Test script for cjson module
-- This tests the built-in cjson.encode and cjson.decode functions

function handle_request(request)
    -- Test encode
    local test_table = {
        name = "test",
        value = 123,
        array = {1, 2, 3},
        nested = {
            key = "value"
        }
    }
    
    local encoded = cjson.encode(test_table)
    
    -- Test decode
    local json_str = '{"status":"ok","count":42}'
    local decoded = cjson.decode(json_str)
    
    -- Return test results
    return {
        status = "success",
        encoded_sample = encoded,
        decoded_status = decoded.status,
        decoded_count = decoded.count,
        cjson_available = cjson ~= nil
    }
end

return {
    handle = handle_request
}

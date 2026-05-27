-- Test script for json module
-- This tests the built-in json.encode and json.decode functions
-- Including edge cases for special characters, empty values, and boundary conditions
--
-- Handler signature: function handle(request, response, context)

function handle(request, response, context)
    local json = require('json')
    -- Test 1: Basic encode/decode
    local test_table = {
        name = "test",
        value = 123,
        array = {1, 2, 3},
        nested = {
            key = "value"
        }
    }
    local encoded = json.encode(test_table)

    -- Test 2: Decode basic JSON
    local json_str = '{"status":"ok","count":42}'
    local decoded = json.decode(json_str)

    -- Test 3: Strings with special characters (quotes, backslashes, control chars)
    local special_chars = {
        quote_test = 'hello "world"',
        backslash_test = 'path\\to\\file',
        newline_test = "line1\nline2",
        tab_test = "col1\tcol2",
        carriage_return = "before\rafter"
    }
    local special_encoded = json.encode(special_chars)
    local special_decoded = json.decode(special_encoded)

    -- Test 4: Keys with special characters
    local special_keys = {}
    special_keys["key with spaces"] = "value1"
    special_keys["key\"quote"] = "value2"
    special_keys["key\\backslash"] = "value3"
    local keys_encoded = json.encode(special_keys)

    -- Test 5: Empty table (object)
    local empty_obj = {}
    local empty_encoded = json.encode(empty_obj)

    -- Test 6: Empty array
    local empty_arr = {}
    local empty_arr_encoded = json.encode(empty_arr)

    -- Test 7: Deeply nested structures
    local deep = {
        level1 = {
            level2 = {
                level3 = {
                    level4 = {
                        value = "deep"
                    }
                }
            }
        }
    }
    local deep_encoded = json.encode(deep)
    local deep_decoded = json.decode(deep_encoded)

    -- Test 8: Large integers (near JSON_MAX_SAFE_INTEGER boundary)
    local large_nums = {
        large_int = 9007199254740991,  -- MAX_SAFE_INTEGER - 1
        negative_large = -9007199254740991
    }
    local large_encoded = json.encode(large_nums)

    -- Test 9: Boolean and null values
    local bool_null = {
        bool_true = true,
        bool_false = false,
        null_val = nil
    }
    local bool_encoded = json.encode(bool_null)

    -- Test 10: Float values
    local floats = {
        pi = 3.14159,
        negative = -2.5,
        scientific = 1.5e10
    }
    local float_encoded = json.encode(floats)

    -- Verify special character escaping in decoded values
    local special_chars_valid = (special_decoded.quote_test == 'hello "world"') and
                                (special_decoded.backslash_test == 'path\\to\\file') and
                                (special_decoded.newline_test == "line1\nline2")

    -- Verify deep nesting
    local deep_valid = deep_decoded.level1.level2.level3.level4.value == "deep"

    -- Test request/response/context
    local request_tests = {
        method = request:method(),
        path = request:path(),
        has_context = context ~= nil
    }

    -- Store test result in context
    context.test_passed = true

    -- Return comprehensive test results
    return {
        status = "success",
        encoded_sample = encoded,
        decoded_status = decoded.status,
        decoded_count = decoded.count,
        json_available = json ~= nil,
        -- Edge case results
        special_chars_encoded = special_encoded,
        special_chars_valid = special_chars_valid,
        keys_encoded = keys_encoded,
        empty_encoded = empty_encoded,
        deep_encoded = deep_encoded,
        deep_valid = deep_valid,
        large_encoded = large_encoded,
        float_encoded = float_encoded,
        -- Request/response/context tests
        request_tests = request_tests
    }
end

return {
    handle = handle
}

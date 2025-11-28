-- Test script for cjson module
-- This tests the built-in cjson.encode and cjson.decode functions
-- Including edge cases for special characters, empty values, and boundary conditions
--
-- Supports both context-based and legacy calling conventions

function handle_test(ctx_or_request)
    -- Test 1: Basic encode/decode
    local test_table = {
        name = "test",
        value = 123,
        array = {1, 2, 3},
        nested = {
            key = "value"
        }
    }
    local encoded = cjson.encode(test_table)
    
    -- Test 2: Decode basic JSON
    local json_str = '{"status":"ok","count":42}'
    local decoded = cjson.decode(json_str)
    
    -- Test 3: Strings with special characters (quotes, backslashes, control chars)
    local special_chars = {
        quote_test = 'hello "world"',
        backslash_test = 'path\\to\\file',
        newline_test = "line1\nline2",
        tab_test = "col1\tcol2",
        carriage_return = "before\rafter"
    }
    local special_encoded = cjson.encode(special_chars)
    local special_decoded = cjson.decode(special_encoded)
    
    -- Test 4: Keys with special characters
    local special_keys = {}
    special_keys["key with spaces"] = "value1"
    special_keys["key\"quote"] = "value2"
    special_keys["key\\backslash"] = "value3"
    local keys_encoded = cjson.encode(special_keys)
    
    -- Test 5: Empty table (object)
    local empty_obj = {}
    local empty_encoded = cjson.encode(empty_obj)
    
    -- Test 6: Empty array
    local empty_arr = {}
    local empty_arr_encoded = cjson.encode(empty_arr)
    
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
    local deep_encoded = cjson.encode(deep)
    local deep_decoded = cjson.decode(deep_encoded)
    
    -- Test 8: Large integers (near JSON_MAX_SAFE_INTEGER boundary)
    local large_nums = {
        large_int = 9007199254740991,  -- MAX_SAFE_INTEGER - 1
        negative_large = -9007199254740991
    }
    local large_encoded = cjson.encode(large_nums)
    
    -- Test 9: Boolean and null values
    local bool_null = {
        bool_true = true,
        bool_false = false,
        null_val = nil
    }
    local bool_encoded = cjson.encode(bool_null)
    
    -- Test 10: Float values
    local floats = {
        pi = 3.14159,
        negative = -2.5,
        scientific = 1.5e10
    }
    local float_encoded = cjson.encode(floats)
    
    -- Verify special character escaping in decoded values
    local special_chars_valid = (special_decoded.quote_test == 'hello "world"') and
                                (special_decoded.backslash_test == 'path\\to\\file') and
                                (special_decoded.newline_test == "line1\nline2")
    
    -- Verify deep nesting
    local deep_valid = deep_decoded.level1.level2.level3.level4.value == "deep"
    
    -- Check if we're in context mode and add some context-specific tests
    local handler_mode = "legacy"
    local context_tests = {}
    
    if ctx_or_request.req then
        handler_mode = "context"
        -- Test context-specific features
        context_tests = {
            method = ctx_or_request.req:method(),
            path = ctx_or_request.req:path(),
            has_data = ctx_or_request.data ~= nil
        }
        -- Store test result in context data
        ctx_or_request.data.test_passed = true
    end
    
    -- Return comprehensive test results
    return {
        status = "success",
        handler_mode = handler_mode,
        encoded_sample = encoded,
        decoded_status = decoded.status,
        decoded_count = decoded.count,
        cjson_available = cjson ~= nil,
        -- Edge case results
        special_chars_encoded = special_encoded,
        special_chars_valid = special_chars_valid,
        keys_encoded = keys_encoded,
        empty_encoded = empty_encoded,
        deep_encoded = deep_encoded,
        deep_valid = deep_valid,
        large_encoded = large_encoded,
        float_encoded = float_encoded,
        -- Context-specific tests (if applicable)
        context_tests = context_tests
    }
end

return {
    handle = handle_test
}

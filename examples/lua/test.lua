-- Example Lua handler for API requests
-- This script handles POST requests to /api/test

function handle_request(request)
    -- Parse request data
    local data = request.body or {}
    
    -- Process the request
    local response = {
        status = "success",
        message = "Hello from Lua!",
        received = data.message or "no message",
        timestamp = os.time(),
        server = "zhttpd with Lua"
    }
    
    -- Return JSON response
    return response
end

-- Export the handler
return {
    handle = handle_request
}

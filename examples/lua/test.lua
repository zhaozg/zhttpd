-- Example Lua handler for API requests
-- This script handles requests to /api/test
--
-- Request object structure (luvit/Node.js style):
-- {
--   method = "GET" or "POST" or ...,
--   path = "/api/test",
--   url = "/api/test",  -- alias for path
--   headers = {
--     ["content-type"] = "application/json",
--     ["user-agent"] = "...",
--     ...
--   },
--   query = {
--     param1 = "value1",
--     param2 = "value2",
--     ...
--   },
--   body = { ... }  -- parsed JSON body for POST/PUT
-- }

function handle_request(request)
    -- Parse request data
    local data = request.body or {}
    
    -- Access headers (luvit/Node.js style)
    local content_type = request.headers and request.headers["content-type"] or "unknown"
    local user_agent = request.headers and request.headers["user-agent"] or "unknown"
    
    -- Access query parameters (luvit/Node.js style)
    local page = request.query and request.query["page"] or "1"
    local limit = request.query and request.query["limit"] or "10"
    
    -- Process the request
    local response = {
        status = "success",
        message = "Hello from Lua!",
        received = data.message or "no message",
        timestamp = os.time(),
        server = "zhttpd with Lua",
        request_info = {
            method = request.method,
            path = request.path,
            content_type = content_type,
            user_agent = user_agent,
            page = page,
            limit = limit
        }
    }
    
    -- Return JSON response
    return response
end

-- Export the handler
return {
    handle = handle_request
}

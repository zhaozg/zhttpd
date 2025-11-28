-- Example Lua handler for API requests
-- This script handles requests to /api/test
--
-- Handler signature: function handle(request, response, context)
--
-- Request object methods:
--   request:method()    -- returns HTTP method (GET, POST, etc.)
--   request:path()      -- returns request path
--   request:url()       -- returns full URL with query string
--   request:header(name) -- returns header value or nil
--   request:headers()   -- returns all headers as table
--   request:query(name) -- returns query parameter value or nil
--   request:query_all() -- returns all query parameters as table
--   request:body()      -- returns parsed JSON body or raw string
--   request:body_raw()  -- returns raw body string
--
-- Response object methods:
--   response:status(code)         -- set HTTP status code
--   response:header(name, value)  -- set response header
--   response:content_type(type)   -- set/get Content-Type header
--   response:body(content)        -- set/get response body
--
-- Context: a Lua table for per-request data storage

function handle(request, response, context)
    -- Access request data via methods
    local method = request:method()
    local path = request:path()
    local content_type = request:header("content-type") or "unknown"
    local user_agent = request:header("user-agent") or "unknown"
    
    -- Access query parameters
    local page = request:query("page") or "1"
    local limit = request:query("limit") or "10"
    
    -- Access body (parsed JSON if valid)
    local body = request:body() or {}
    
    -- Store data in per-request context
    context.processed_at = os.time()
    context.handler_version = "3.0"
    
    -- You can also set response properties directly:
    -- response:status(200)
    -- response:header("X-Processed-By", "zhttpd-lua")
    
    -- Build response
    local result = {
        status = "success",
        message = "Hello from Lua!",
        received = body.message or "no message",
        timestamp = os.time(),
        server = "zhttpd with Lua",
        request_info = {
            method = method,
            path = path,
            content_type = content_type,
            user_agent = user_agent,
            page = page,
            limit = limit
        },
        context_data = {
            processed_at = context.processed_at,
            handler_version = context.handler_version
        }
    }
    
    return result
end

-- Export the handler
return {
    handle = handle
}

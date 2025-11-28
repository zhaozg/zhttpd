-- Example Lua handler for API requests
-- This script handles requests to /api/test
--
-- This script supports two calling conventions:
-- 1. New context-based style (ctx object with req, res, data)
-- 2. Legacy style (request table with method, path, headers, etc.)
--
-- New Context-based API (preferred):
-- {
--   req = {
--     :method()    -- returns HTTP method (GET, POST, etc.)
--     :path()      -- returns request path
--     :url()       -- returns full URL with query string
--     :header(name) -- returns header value or nil
--     :headers()   -- returns all headers as table
--     :query(name) -- returns query parameter value or nil
--     :query_all() -- returns all query parameters as table
--     :body()      -- returns parsed JSON body or raw string
--     :body_raw()  -- returns raw body string
--   },
--   res = {
--     :status(code)         -- set HTTP status code
--     :header(name, value)  -- set response header
--     :content_type(type)   -- set Content-Type header
--     :body(content)        -- set response body
--   },
--   data = {}  -- per-request data storage (Lua table)
-- }
--
-- Legacy request object structure (luvit/Node.js style):
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

function handle_request(ctx_or_request)
    -- Detect which calling convention is being used
    if ctx_or_request.req then
        -- New context-based style
        return handle_with_context(ctx_or_request)
    else
        -- Legacy style (request table)
        return handle_legacy(ctx_or_request)
    end
end

-- New context-based handler
function handle_with_context(ctx)
    -- Access request data via methods
    local method = ctx.req:method()
    local path = ctx.req:path()
    local content_type = ctx.req:header("content-type") or "unknown"
    local user_agent = ctx.req:header("user-agent") or "unknown"
    
    -- Access query parameters
    local page = ctx.req:query("page") or "1"
    local limit = ctx.req:query("limit") or "10"
    
    -- Access body (parsed JSON if valid)
    local body = ctx.req:body() or {}
    
    -- Store data in per-request context
    ctx.data.processed_at = os.time()
    ctx.data.handler_version = "2.0"
    
    -- You can also set response properties directly:
    -- ctx.res:status(200)
    -- ctx.res:header("X-Processed-By", "zhttpd-lua")
    
    -- Build response
    local response = {
        status = "success",
        message = "Hello from Lua! (context mode)",
        received = body.message or "no message",
        timestamp = os.time(),
        server = "zhttpd with Lua",
        handler_mode = "context",
        request_info = {
            method = method,
            path = path,
            content_type = content_type,
            user_agent = user_agent,
            page = page,
            limit = limit
        },
        context_data = {
            processed_at = ctx.data.processed_at,
            handler_version = ctx.data.handler_version
        }
    }
    
    return response
end

-- Legacy handler (for backward compatibility)
function handle_legacy(request)
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
        message = "Hello from Lua! (legacy mode)",
        received = data.message or "no message",
        timestamp = os.time(),
        server = "zhttpd with Lua",
        handler_mode = "legacy",
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

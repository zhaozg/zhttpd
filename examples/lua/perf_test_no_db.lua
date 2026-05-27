-- Performance test: Handler without database access
-- This script tests the baseline performance of Lua handlers
-- that don't use the database at all

function handle(request, response, context)
    -- Simple request processing without database
    local method = request:method()
    local path = request:path()

    -- Store some context data
    context.processed = true
    context.timestamp = os.time()

    -- Return JSON response
    response:status(200)
    response:content_type("application/json")

    return {
        status = "success",
        method = method,
        path = path,
        timestamp = context.timestamp
    }
end

return { handle = handle }

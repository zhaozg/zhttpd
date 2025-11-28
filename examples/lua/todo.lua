-- Complete Lua Dynamic Page Example
-- Demonstrates GET and POST request handling with thread-safe execution
-- This example implements a simple todo list API
--
-- Supports both context-based and legacy calling conventions
-- See docs/LUA_PROGRAMMING_GUIDE.md for API documentation

-- In-memory storage (each Lua state has its own copy)
-- For production, use a shared database or cache
local todos = {}
local next_id = 1

-- Helper function to generate response
local function response(status, data, message)
    return {
        status = status,
        data = data,
        message = message or "",
        timestamp = os.time()
    }
end

-- GET /api/todo - List all todos
local function list_todos()
    local todo_list = {}
    for _, todo in pairs(todos) do
        table.insert(todo_list, todo)
    end
    return response("success", { todos = todo_list })
end

-- GET /api/todo/:id - Get a specific todo
local function get_todo(id)
    local todo = todos[id]
    if todo then
        return response("success", todo)
    else
        return response("error", nil, "Todo not found")
    end
end

-- POST /api/todo - Create a new todo
local function create_todo(body)
    if not body or not body.title then
        return response("error", nil, "Title is required"), 400
    end
    
    local todo = {
        id = next_id,
        title = body.title,
        description = body.description or "",
        completed = false,
        created_at = os.time()
    }
    
    todos[next_id] = todo
    next_id = next_id + 1
    
    return response("success", todo, "Todo created successfully"), 201
end

-- POST /api/todo/:id/complete - Mark todo as completed
local function complete_todo(id)
    local todo = todos[id]
    if todo then
        todo.completed = true
        todo.completed_at = os.time()
        return response("success", todo, "Todo marked as completed")
    else
        return response("error", nil, "Todo not found"), 404
    end
end

-- Context-based handler (preferred)
local function handle_with_context(ctx)
    local method = ctx.req:method()
    local path = ctx.req:path()
    local body = ctx.req:body()
    
    -- Store request start time in context
    ctx.data.start_time = os.time()
    
    local result, status
    
    if method == "GET" then
        -- List all todos
        if path == "/api/todo" then
            result = list_todos()
        else
            -- Get specific todo (match /api/todo/123)
            local id = path:match("/api/todo/(%d+)$")
            if id then
                result = get_todo(tonumber(id))
                if result.status == "error" then
                    status = 404
                end
            else
                result = response("error", nil, "Route not found")
                status = 404
            end
        end
    elseif method == "POST" then
        -- Create new todo
        if path == "/api/todo" then
            result, status = create_todo(body)
        else
            -- Complete todo (match /api/todo/123/complete)
            local id = path:match("/api/todo/(%d+)/complete$")
            if id then
                result, status = complete_todo(tonumber(id))
            else
                result = response("error", nil, "Route not found")
                status = 404
            end
        end
    else
        result = response("error", nil, "Method not allowed")
        status = 405
    end
    
    -- Set response status if not 200
    if status then
        ctx.res:status(status)
    end
    
    return result
end

-- Legacy handler (for backward compatibility)
local function handle_legacy(request)
    local method = request.method
    local path = request.path
    local body = request.body
    
    -- Route the request
    if method == "GET" then
        -- List all todos
        if path == "/api/todo" then
            return list_todos()
        end
        
        -- Get specific todo (match /api/todo/123)
        local id = path:match("/api/todo/(%d+)$")
        if id then
            return get_todo(tonumber(id))
        end
        
        return response("error", nil, "Route not found")
        
    elseif method == "POST" then
        -- Create new todo
        if path == "/api/todo" then
            return create_todo(body)
        end
        
        -- Complete todo (match /api/todo/123/complete)
        local id = path:match("/api/todo/(%d+)/complete$")
        if id then
            return complete_todo(tonumber(id))
        end
        
        return response("error", nil, "Route not found")
        
    else
        return response("error", nil, "Method not allowed")
    end
end

-- Main request handler - detect calling convention
function handle_request(ctx_or_request)
    if ctx_or_request.req then
        return handle_with_context(ctx_or_request)
    else
        return handle_legacy(ctx_or_request)
    end
end

-- Export the handler
return {
    handle = handle_request
}

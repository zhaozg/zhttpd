-- Complete Lua Dynamic Page Example
-- Demonstrates GET and POST request handling with thread-safe execution
-- This example implements a simple todo list API

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
        return response("error", nil, "Title is required")
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
    
    return response("success", todo, "Todo created successfully")
end

-- POST /api/todo/:id/complete - Mark todo as completed
local function complete_todo(id)
    local todo = todos[id]
    if todo then
        todo.completed = true
        todo.completed_at = os.time()
        return response("success", todo, "Todo marked as completed")
    else
        return response("error", nil, "Todo not found")
    end
end

-- Main request handler
function handle_request(request)
    local method = request.method
    local path = request.path
    local body = request.body
    
    -- Note: Request logging is handled by the server's access log
    -- Avoid print() here for performance in high-load scenarios
    
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

-- Export the handler
return {
    handle = handle_request
}

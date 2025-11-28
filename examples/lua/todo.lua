-- Complete Lua Dynamic Page Example
-- Demonstrates GET and POST request handling with thread-safe execution
-- This example implements a simple todo list API
--
-- Handler signature: function handle(request, response, context)
-- See docs/LUA_PROGRAMMING_GUIDE.md for API documentation

-- In-memory storage (each Lua state has its own copy)
-- For production, use a shared database or cache
local todos = {}
local next_id = 1

-- Helper function to generate response
local function make_response(status, data, message)
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
    return make_response("success", { todos = todo_list }), 200
end

-- GET /api/todo/:id - Get a specific todo
local function get_todo(id)
    local todo = todos[id]
    if todo then
        return make_response("success", todo), 200
    else
        return make_response("error", nil, "Todo not found"), 404
    end
end

-- POST /api/todo - Create a new todo
local function create_todo(body)
    if not body or not body.title then
        return make_response("error", nil, "Title is required"), 400
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
    
    return make_response("success", todo, "Todo created successfully"), 201
end

-- POST /api/todo/:id/complete - Mark todo as completed
local function complete_todo(id)
    local todo = todos[id]
    if todo then
        todo.completed = true
        todo.completed_at = os.time()
        return make_response("success", todo, "Todo marked as completed"), 200
    else
        return make_response("error", nil, "Todo not found"), 404
    end
end

-- Handler with new signature: handle(request, response, context)
function handle(request, response, context)
    local method = request:method()
    local path = request:path()
    local body = request:body()
    
    -- Store request start time in context
    context.start_time = os.time()
    
    local result, status
    
    if method == "GET" then
        -- List all todos
        if path == "/api/todo" then
            result, status = list_todos()
        else
            -- Get specific todo (match /api/todo/123)
            local id = path:match("/api/todo/(%d+)$")
            if id then
                result, status = get_todo(tonumber(id))
            else
                result = make_response("error", nil, "Route not found")
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
                result = make_response("error", nil, "Route not found")
                status = 404
            end
        end
    else
        result = make_response("error", nil, "Method not allowed")
        status = 405
    end
    
    -- Set response status
    if status then
        response:status(status)
    end
    
    return result
end

-- Export the handler
return {
    handle = handle
}

-- Example: User management API
-- Handles user-related operations
--
-- This script supports both context-based and legacy calling conventions
-- See docs/LUA_PROGRAMMING_GUIDE.md for API documentation

local users = {}
local next_id = 1

function get_user(user_id)
    return users[user_id] or { error = "User not found" }
end

function create_user(user_data)
    local id = next_id
    users[id] = {
        id = id,
        name = user_data.name,
        email = user_data.email,
        created_at = os.time()
    }
    next_id = next_id + 1
    return users[id]
end

function list_users()
    local user_list = {}
    for _, user in pairs(users) do
        table.insert(user_list, user)
    end
    return user_list
end

-- Context-based handler (preferred)
function handle_with_context(ctx)
    local method = ctx.req:method()
    local path = ctx.req:path()
    
    -- GET /api/users/:id - Get specific user
    local user_id = path:match("/api/users/(%d+)$")
    if method == "GET" and user_id then
        local user = get_user(tonumber(user_id))
        if user.error then
            ctx.res:status(404)
        end
        return user
    end
    
    -- GET /api/users - List all users
    if method == "GET" and path == "/api/users" then
        return { users = list_users() }
    end
    
    -- POST /api/users - Create new user
    if method == "POST" and path == "/api/users" then
        local body = ctx.req:body()
        if not body or not body.name then
            ctx.res:status(400)
            return { error = "Name is required" }
        end
        local user = create_user(body)
        ctx.res:status(201)
        return user
    end
    
    ctx.res:status(404)
    return { error = "Not found" }
end

-- Legacy handler (for backward compatibility)
function handle_legacy(request)
    local method = request.method
    local path = request.path
    
    if method == "GET" and path:match("/api/users/(%d+)") then
        local user_id = tonumber(path:match("/api/users/(%d+)"))
        return get_user(user_id)
    elseif method == "GET" and path == "/api/users" then
        return { users = list_users() }
    elseif method == "POST" and path == "/api/users" then
        return create_user(request.body)
    else
        return { error = "Not found", status = 404 }
    end
end

-- Main handler - detect calling convention
function handle_request(ctx_or_request)
    if ctx_or_request.req then
        return handle_with_context(ctx_or_request)
    else
        return handle_legacy(ctx_or_request)
    end
end

return {
    handle = handle_request
}

-- Example: User management API
-- Handles user-related operations

local users = {}

function get_user(user_id)
    return users[user_id] or { error = "User not found" }
end

function create_user(user_data)
    local id = #users + 1
    users[id] = {
        id = id,
        name = user_data.name,
        email = user_data.email,
        created_at = os.time()
    }
    return users[id]
end

function list_users()
    local user_list = {}
    for _, user in pairs(users) do
        table.insert(user_list, user)
    end
    return user_list
end

function handle_request(request)
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

return {
    handle = handle_request
}

-- Example: User management API
-- Handles user-related operations
--
-- Handler signature: function handle(request, response, context)
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
    created_at = os.time(),
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

-- Handler with new signature: handle(request, response, context)
function handle(request, response, context)
  local method = request:method()
  local path = request:path()

  -- GET /api/users/:id - Get specific user
  local user_id = path:match("/api/users/(%d+)$")
  if method == "GET" and user_id then
    local user = get_user(tonumber(user_id))
    if user.error then
      response:status(404)
    end
    return user
  end

  -- GET /api/users - List all users
  if method == "GET" and path == "/api/users" then
    return { users = list_users() }
  end

  -- POST /api/users - Create new user
  if method == "POST" and path == "/api/users" then
    local body = request:body()
    if not body or not body.name then
      response:status(400)
      return { error = "Name is required" }
    end
    local user = create_user(body)
    response:status(201)
    return user
  end

  response:status(404)
  return { error = "Not found" }
end

return {
  handle = handle,
}

-- Example: User management API with Database
-- Handles user-related operations using the database plugin
--
-- Handler signature: function handle(request, response, context)
-- See docs/LUA_PROGRAMMING_GUIDE.md for API documentation
--
-- Database access is through context:db(name) where name is optional
-- (defaults to "default" data source)
--
-- Database Requirements:
-- Before using this API, ensure the database is configured and has the users table:
--
-- CREATE TABLE users (
--     id INTEGER PRIMARY KEY AUTOINCREMENT,
--     name TEXT NOT NULL,
--     email TEXT UNIQUE,
--     password_hash TEXT,
--     roles TEXT DEFAULT 'user',
--     active INTEGER DEFAULT 1,
--     created_at INTEGER DEFAULT (strftime('%s', 'now'))
-- );
--
-- Configuration (in config.yaml):
-- enable_db: true
-- db_uri: "sqlite:///data/app.db"
-- db_pool_size: 5
-- # Or use named data sources:
-- # data_sources:
-- #   - name: default
-- #     uri: "sqlite:///data/app.db"
-- #     pool_size: 5

-- Fallback to in-memory storage if database is not available
local memory_users = {}
local next_id = 1

-- Get user by ID (database or memory)
function get_user(db, user_id)
  if db then
    local result, err =
      db:query("SELECT id, name, email, roles, created_at FROM users WHERE id = ? AND active = 1", user_id)
    if err then
      return { error = "Database error: " .. tostring(err) }
    end
    if result and #result > 0 then
      return result[1]
    end
    return { error = "User not found" }
  else
    return memory_users[user_id] or { error = "User not found" }
  end
end

-- Create new user
function create_user(db, user_data)
  if db then
    local affected, err = db:exec(
      "INSERT INTO users (name, email, roles) VALUES (?, ?, ?)",
      user_data.name,
      user_data.email or "",
      user_data.roles or "user"
    )
    if err then
      return nil, "Database error: " .. tostring(err)
    end
    -- Get the last inserted row ID (SQLite-specific, but works for most DBs)
    local id_result = db:query("SELECT last_insert_rowid() AS id")
    if id_result and #id_result > 0 and id_result[1].id then
      local user_id = id_result[1].id
      local result = db:query("SELECT id, name, email, roles, created_at FROM users WHERE id = ?", user_id)
      if result and #result > 0 then
        return result[1], nil
      end
    end
    -- Fallback: return what we know about the user
    return { name = user_data.name, email = user_data.email }, nil
  else
    local id = next_id
    memory_users[id] = {
      id = id,
      name = user_data.name,
      email = user_data.email,
      roles = user_data.roles or "user",
      created_at = os.time(),
    }
    next_id = next_id + 1
    return memory_users[id], nil
  end
end

-- List all users
function list_users(db, page, limit)
  page = page or 1
  limit = limit or 10
  local offset = (page - 1) * limit

  if db then
    local result, err = db:query(
      "SELECT id, name, email, roles, created_at FROM users WHERE active = 1 ORDER BY id LIMIT ? OFFSET ?",
      limit,
      offset
    )
    if err then
      return nil, "Database error: " .. tostring(err)
    end
    return result or {}, nil
  else
    local user_list = {}
    local count = 0
    for _, user in pairs(memory_users) do
      count = count + 1
      if count > offset and #user_list < limit then
        table.insert(user_list, user)
      end
    end
    return user_list, nil
  end
end

-- Update user
function update_user(db, user_id, user_data)
  if db then
    local affected, err = db:exec(
      "UPDATE users SET name = ?, email = ? WHERE id = ? AND active = 1",
      user_data.name or "",
      user_data.email or "",
      user_id
    )
    if err then
      return nil, "Database error: " .. tostring(err)
    end
    return get_user(db, user_id), nil
  else
    local user = memory_users[user_id]
    if not user then
      return nil, "User not found"
    end
    if user_data.name then
      user.name = user_data.name
    end
    if user_data.email then
      user.email = user_data.email
    end
    return user, nil
  end
end

-- Delete user (soft delete)
function delete_user(db, user_id)
  if db then
    local affected, err = db:exec("UPDATE users SET active = 0 WHERE id = ?", user_id)
    if err then
      return false, "Database error: " .. tostring(err)
    end
    return true, nil
  else
    if memory_users[user_id] then
      memory_users[user_id] = nil
      return true, nil
    end
    return false, "User not found"
  end
end

-- Handler with new signature: handle(request, response, context)
function handle(request, response, context)
  local method = request:method()
  local path = request:path()

  -- Get database connection from context (nil if not configured)
  local db = context:db() -- Gets the "default" data source
  local db_available = db ~= nil

  -- Parse query parameters for pagination
  local page = tonumber(request:query("page")) or 1
  local limit = tonumber(request:query("limit")) or 10

  -- GET /api/users/:id - Get specific user
  local user_id = path:match("/api/users/(%d+)$")
  if method == "GET" and user_id then
    local user = get_user(db, tonumber(user_id))
    if user.error then
      response:status(404)
    end
    return {
      status = user.error and "error" or "success",
      data = user,
      db_enabled = db_available,
    }
  end

  -- GET /api/users - List all users
  if method == "GET" and path == "/api/users" then
    local users, err = list_users(db, page, limit)
    if err then
      response:status(500)
      return { status = "error", message = err }
    end
    return {
      status = "success",
      data = { users = users },
      pagination = { page = page, limit = limit },
      db_enabled = db_available,
    }
  end

  -- POST /api/users - Create new user
  if method == "POST" and path == "/api/users" then
    local body = request:body()
    if not body or not body.name then
      response:status(400)
      return { status = "error", message = "Name is required" }
    end
    local user, err = create_user(db, body)
    if err then
      response:status(500)
      return { status = "error", message = err }
    end
    response:status(201)
    return {
      status = "success",
      data = user,
      db_enabled = db_available,
    }
  end

  -- PUT /api/users/:id - Update user
  if method == "PUT" and user_id then
    local body = request:body()
    if not body then
      response:status(400)
      return { status = "error", message = "Request body is required" }
    end
    local user, err = update_user(db, tonumber(user_id), body)
    if err then
      response:status(500)
      return { status = "error", message = err }
    end
    return {
      status = "success",
      data = user,
      db_enabled = db_available,
    }
  end

  -- DELETE /api/users/:id - Delete user
  if method == "DELETE" and user_id then
    local success, err = delete_user(db, tonumber(user_id))
    if not success then
      response:status(404)
      return { status = "error", message = err or "User not found" }
    end
    return {
      status = "success",
      message = "User deleted",
      db_enabled = db_available,
    }
  end

  response:status(404)
  return { status = "error", message = "Not found" }
end

return {
  handle = handle,
}

-- Example: Database Prepared Statements with Caching
-- This script demonstrates the new prepare() API for efficient statement caching
--
-- The refactored db API provides three ways to execute SQL:
--   1. db.query(sql, ...) - Direct query without caching
--   2. db.exec(sql, ...)  - Direct exec without caching
--   3. db:prepare(sql)    - Prepare statement with caching (returns statement object)
--
-- Prepared statements are automatically cached and reused, improving performance
-- for frequently executed queries.
--
-- Endpoints:
--   POST /api/prepared/init          - Initialize database schema
--   POST /api/prepared/users         - Insert user (using prepared statement)
--   GET  /api/prepared/users/:id     - Get user by ID (using prepared statement)
--   GET  /api/prepared/users         - List all users (direct query)
--   PUT  /api/prepared/users/:id     - Update user (using prepared statement)
--   DELETE /api/prepared/users/:id   - Delete user (using prepared statement)
--   GET  /api/prepared/stats         - Get cache statistics

-- Initialize database schema
local function init_schema(db)
  if not db then
    return false, "Database not available"
  end

  -- Direct exec for schema creation (not cached, run once)
  local affected, err = db:exec([[
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            email TEXT UNIQUE NOT NULL,
            full_name TEXT NOT NULL,
            created_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]])
  if err then
    return false, "Failed to create users table: " .. tostring(err)
  end

  return true, "Schema initialized successfully"
end

-- Parse ID from path like /api/prepared/users/123
local function parse_id_from_path(path)
  local id_str = path:match("/api/prepared/users/(%d+)")
  if id_str then
    return tonumber(id_str)
  end
  return nil
end

-- Handler
function handle(request, response, context)
  local method = request:method()
  local path = request:path()

  -- Get database connection from context
  local db, db_err = context:db()
  if not db then
    response:status(503)
    return {
      status = "error",
      message = "Database not available: " .. (db_err or "unknown error"),
    }
  end

  -- POST /api/prepared/init - Initialize schema
  if method == "POST" and path == "/api/prepared/init" then
    local success, message = init_schema(db)
    if success then
      response:status(200)
      return {
        status = "success",
        message = message,
      }
    else
      response:status(500)
      return {
        status = "error",
        message = message,
      }
    end
  end

  -- POST /api/prepared/users - Insert user using prepared statement
  if method == "POST" and (path == "/api/prepared/users" or path == "/api/prepared/users/") then
    local body = request:body()
    if not body or not body.username or not body.email or not body.full_name then
      response:status(400)
      return {
        status = "error",
        message = "username, email, and full_name are required",
      }
    end

    -- Use prepared statement for insert (will be cached)
    local stmt = db:prepare("INSERT INTO users (username, email, full_name) VALUES (?, ?, ?)")
    if not stmt then
      response:status(500)
      return {
        status = "error",
        message = "Failed to prepare statement",
      }
    end

    local affected, err = stmt:exec(body.username, body.email, body.full_name)
    if err then
      response:status(500)
      return {
        status = "error",
        message = "Insert failed: " .. tostring(err),
      }
    end

    response:status(201)
    return {
      status = "success",
      affected_rows = affected,
      message = "User created successfully",
    }
  end

  -- GET /api/prepared/users/:id - Get user by ID using prepared statement
  local user_id = parse_id_from_path(path)
  if method == "GET" and user_id then
    -- Use prepared statement for select (will be cached)
    local stmt = db:prepare("SELECT id, username, email, full_name, created_at FROM users WHERE id = ?")
    if not stmt then
      response:status(500)
      return {
        status = "error",
        message = "Failed to prepare statement",
      }
    end

    local result, err = stmt:query(user_id)
    if err then
      response:status(500)
      return {
        status = "error",
        message = "Query failed: " .. tostring(err),
      }
    end

    if not result or #result == 0 then
      response:status(404)
      return {
        status = "error",
        message = "User not found",
      }
    end

    return {
      status = "success",
      user = result[1],
    }
  end

  -- GET /api/prepared/users - List all users (direct query, not cached)
  if method == "GET" and (path == "/api/prepared/users" or path == "/api/prepared/users/") then
    -- Direct query without caching (good for infrequent queries)
    local result, err =
      db.query("SELECT id, username, email, full_name, created_at FROM users ORDER BY created_at DESC")
    if err then
      response:status(500)
      return {
        status = "error",
        message = "Query failed: " .. tostring(err),
      }
    end

    return {
      status = "success",
      users = result,
      count = result and #result or 0,
    }
  end

  -- PUT /api/prepared/users/:id - Update user using prepared statement
  if method == "PUT" and user_id then
    local body = request:body()
    if not body or (not body.username and not body.email and not body.full_name) then
      response:status(400)
      return {
        status = "error",
        message = "At least one field (username, email, or full_name) is required",
      }
    end

    -- Build dynamic update query (in production, validate fields)
    local fields = {}
    local values = {}

    if body.username then
      table.insert(fields, "username = ?")
      table.insert(values, body.username)
    end
    if body.email then
      table.insert(fields, "email = ?")
      table.insert(values, body.email)
    end
    if body.full_name then
      table.insert(fields, "full_name = ?")
      table.insert(values, body.full_name)
    end

    table.insert(values, user_id)

    local update_sql = "UPDATE users SET " .. table.concat(fields, ", ") .. " WHERE id = ?"

    -- Use prepared statement (will be cached for each unique SQL)
    local stmt = db:prepare(update_sql)
    if not stmt then
      response:status(500)
      return {
        status = "error",
        message = "Failed to prepare statement",
      }
    end

    local affected, err = stmt:exec(table.unpack(values))
    if err then
      response:status(500)
      return {
        status = "error",
        message = "Update failed: " .. tostring(err),
      }
    end

    if affected == 0 then
      response:status(404)
      return {
        status = "error",
        message = "User not found",
      }
    end

    return {
      status = "success",
      affected_rows = affected,
      message = "User updated successfully",
    }
  end

  -- DELETE /api/prepared/users/:id - Delete user using prepared statement
  if method == "DELETE" and user_id then
    -- Use prepared statement for delete (will be cached)
    local stmt = db:prepare("DELETE FROM users WHERE id = ?")
    if not stmt then
      response:status(500)
      return {
        status = "error",
        message = "Failed to prepare statement",
      }
    end

    local affected, err = stmt:exec(user_id)
    if err then
      response:status(500)
      return {
        status = "error",
        message = "Delete failed: " .. tostring(err),
      }
    end

    if affected == 0 then
      response:status(404)
      return {
        status = "error",
        message = "User not found",
      }
    end

    return {
      status = "success",
      affected_rows = affected,
      message = "User deleted successfully",
    }
  end

  -- GET /api/prepared/stats - Get cache statistics
  if method == "GET" and path == "/api/prepared/stats" then
    local status = db:status()

    response:status(200)
    return {
      status = "success",
      db_status = status,
      cache_stats = status.stmt_cache_stats,
    }
  end

  response:status(404)
  return {
    status = "error",
    message = "Not found",
  }
end

return {
  handle = handle,
}

-- Example: Database Status and Test API
-- This script provides endpoints to check database status and perform basic tests
--
-- Database access is through context:db(name) where name is optional
-- (defaults to "default" data source)
--
-- Endpoints:
--   GET /api/db_test              - Check database status
--   POST /api/db_test/exec        - Execute SQL (DANGEROUS - admin only!)
--   POST /api/db_test/query       - Query SQL (DANGEROUS - admin only!)
--   POST /api/db_test/init        - Initialize database schema
--
-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  ⚠️  SECURITY WARNING                                                ║
-- ║                                                                      ║
-- ║  The /api/db_test/exec and /api/db_test/query endpoints execute     ║
-- ║  arbitrary SQL without authentication! This is a CRITICAL security  ║
-- ║  vulnerability if exposed to untrusted users.                        ║
-- ║                                                                      ║
-- ║  In production:                                                      ║
-- ║    1. REMOVE these endpoints entirely, OR                            ║
-- ║    2. Add authentication and authorization checks                    ║
-- ║    3. Restrict to localhost/internal network only                    ║
-- ║    4. Never accept raw SQL from untrusted clients                    ║
-- ╚══════════════════════════════════════════════════════════════════════╝

-- Initialize database schema
local function init_schema(db)
  if not db then
    return false, "Database not available"
  end

  -- Create users table
  local affected, err = db:exec([[
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE,
            name TEXT NOT NULL,
            email TEXT UNIQUE,
            password_hash TEXT,
            roles TEXT DEFAULT 'user',
            active INTEGER DEFAULT 1,
            created_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ]])
  if err then
    return false, "Failed to create users table: " .. tostring(err)
  end

  -- Create sessions table
  affected, err = db:exec([[
        CREATE TABLE IF NOT EXISTS sessions (
            token TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            FOREIGN KEY (user_id) REFERENCES users(id)
        )
    ]])
  if err then
    return false, "Failed to create sessions table: " .. tostring(err)
  end

  -- Insert demo user if not exists
  affected, err = db:exec([[
        INSERT OR IGNORE INTO users (username, name, email, password_hash, roles)
        VALUES ('admin', 'Administrator', 'admin@example.com', 'demo', 'admin'),
               ('user1', 'Test User', 'user1@example.com', 'demo', 'user')
    ]])
  if err then
    return false, "Failed to insert demo users: " .. tostring(err)
  end

  return true, "Schema initialized successfully"
end

-- Handler
function handle(request, response, context)
  local method = request:method()
  local path = request:path()

  -- Get database connection from context
  -- You can also specify a data source name: context:db("users_db")
  local db, db_err = context:db() -- Gets the "default" data source
  local db_available = db ~= nil

  -- GET /api/db_test - Database status
  if method == "GET" and (path == "/api/db_test" or path == "/api/db_test/") then
    if db_available then
      local status = db:status()
      return {
        status = "success",
        db_available = true,
        db_status = status,
      }
    else
      return {
        status = "success",
        db_available = false,
        message = db_err or "Database plugin not enabled or not configured",
      }
    end
  end

  -- POST /api/db_test/init - Initialize schema
  if method == "POST" and path == "/api/db_test/init" then
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

  -- POST /api/db_test/exec - Execute SQL
  if method == "POST" and path == "/api/db_test/exec" then
    if not db_available then
      response:status(503)
      return { status = "error", message = "Database not available" }
    end

    local body = request:body()
    if not body or not body.sql then
      response:status(400)
      return { status = "error", message = "SQL statement required" }
    end

    -- Execute the SQL
    local affected, err = db:exec(body.sql)
    if err then
      response:status(500)
      return {
        status = "error",
        message = "SQL execution failed: " .. tostring(err),
      }
    end

    return {
      status = "success",
      affected_rows = affected,
    }
  end

  -- POST /api/db_test/query - Query SQL
  if method == "POST" and path == "/api/db_test/query" then
    if not db_available then
      response:status(503)
      return { status = "error", message = "Database not available" }
    end

    local body = request:body()
    if not body or not body.sql then
      response:status(400)
      return { status = "error", message = "SQL query required" }
    end

    -- Execute the query
    local result, err = db:query(body.sql)
    if err then
      response:status(500)
      return {
        status = "error",
        message = "SQL query failed: " .. tostring(err),
      }
    end

    return {
      status = "success",
      rows = result,
      count = result and #result or 0,
    }
  end

  response:status(404)
  return { status = "error", message = "Not found" }
end

return {
  handle = handle,
}

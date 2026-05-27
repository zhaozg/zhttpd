-- Performance test: Handler with database access
-- This script tests the performance of Lua handlers that use the database
-- Measures the overhead of context:db() calls and database operations

function handle(request, response, context)
  -- Access database through context
  local db, db_err = context:db()

  if not db then
    return {
      status = "error",
      message = "Database not available: " .. tostring(db_err),
      note = "This is expected if database is not configured",
    }
  end

  -- Get database status (lightweight operation for testing overhead)
  local status = db:status()

  -- Store some context data
  context.processed = true
  context.timestamp = os.time()
  context.db_connected = status.connected

  -- Return JSON response
  response:status(200)
  response:content_type("application/json")

  return {
    status = "success",
    db_connected = status.connected,
    timestamp = context.timestamp,
  }
end

return { handle = handle }

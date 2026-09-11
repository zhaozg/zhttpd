-- WebSocket Handler Script for zhttpd
-- This script handles WebSocket messages and events
--
-- Event types:
--   connect    - New client connected
--   message    - Client sent a message
--   disconnect - Client disconnected
--
-- Request object structure:
-- {
--   type = "connect" | "message" | "disconnect",
--   connection_id = <number>,
--   path = "/ws",
--   data = <message data (for message type)>
-- }
--
-- The handler should return a response table that will be serialized to JSON
-- and sent back to the client.
--
-- STATE MANAGEMENT NOTE:
-- The connections table is module-level state that persists
-- across all WebSocket connections within the same Lua interpreter instance.
-- This means:
-- 1. State is shared across all connections (useful for broadcasting)
-- 2. State will be lost if the Lua script is reloaded
-- 3. For production use with multiple server instances, consider external
--    state storage (Redis, database, etc.)

-- Store active connections (shared across all WebSocket handlers)
local connections = {}
local json = require("json")

-- Handle new connection
local function handle_connect(request)
  local conn_id = request.connection_id
  connections[conn_id] = {
    id = conn_id,
    path = request.path,
    connected_at = os.time(),
  }

  return {
    type = "connected",
    message = "Welcome to zhttpd WebSocket!",
    connection_id = conn_id,
  }
end

-- Handle client disconnect
local function handle_disconnect(request)
  local conn_id = request.connection_id

  -- Remove connection
  connections[conn_id] = nil

  return {
    type = "disconnected",
    connection_id = conn_id,
  }
end

-- Handle incoming message
local function handle_message(request)
  local data = request.data or ""

  -- Parse incoming JSON message
  local parsed = json.decode(data)

  -- Handle ping/pong for keeping connection alive
  if parsed and parsed.type == "ping" then
    return {
      type = "pong",
      timestamp = os.time(),
    }
  end

  -- Regular WebSocket message handling
  -- Echo the message back with metadata
  return {
    type = "message",
    connection_id = request.connection_id,
    received = data,
    timestamp = os.time(),
    echo = true,
  }
end

-- Export the handlers. httpz/zhttpd looks up the function matching the
-- event type (handle_connect / handle_message / handle_disconnect).
return {
  handle_connect = handle_connect,
  handle_message = handle_message,
  handle_disconnect = handle_disconnect,
}

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

-- Handle new connection
local function handle_connect(request)
    local conn_id = request.connection_id
    connections[conn_id] = {
        id = conn_id,
        path = request.path,
        connected_at = os.time()
    }
    
    return {
        type = "connected",
        message = "Welcome to zhttpd WebSocket!",
        connection_id = conn_id
    }
end

-- Handle client disconnect
local function handle_disconnect(request)
    local conn_id = request.connection_id
    
    -- Remove connection
    connections[conn_id] = nil
    
    return {
        type = "disconnected",
        connection_id = conn_id
    }
end

-- Parse JSON string (simple parser for basic cases)
-- LIMITATIONS:
-- This is a simplified pattern-based parser suitable for WebSocket messages.
-- It only handles:
-- - Simple string values for "type" and "id" fields
-- - Top-level "payload" object (as raw string)
-- It does NOT handle:
-- - Nested objects within string values
-- - Escaped quotes within strings
-- - Arrays, numbers, or boolean values
-- - Complex nested structures
-- For production use with complex JSON, use the built-in json module or integrate lua-cjson.
local function parse_json(str)
    -- Try to use a simple pattern-based approach for common cases
    -- This is a simplified parser - for production use json module
    if str == "" or str == nil then
        return {}
    end
    
    -- Handle simple object with type field
    local type_match = str:match('"type"%s*:%s*"([^"]*)"')
    local id_match = str:match('"id"%s*:%s*"([^"]*)"')
    local payload_match = str:match('"payload"%s*:%s*(%b{})')
    
    local result = {}
    if type_match then result.type = type_match end
    if id_match then result.id = id_match end
    if payload_match then result.payload = payload_match end
    
    return result
end

-- Handle incoming message
local function handle_message(request)
    local data = request.data or ""
    
    -- Parse incoming JSON message
    local parsed = parse_json(data)
    
    -- Handle ping/pong for keeping connection alive
    if parsed.type == "ping" then
        return {
            type = "pong",
            timestamp = os.time()
        }
    end
    
    -- Regular WebSocket message handling
    -- Echo the message back with metadata
    return {
        type = "message",
        connection_id = request.connection_id,
        received = data,
        timestamp = os.time(),
        echo = true
    }
end

-- Main request handler
function handle_request(request)
    local event_type = request.type or request.body and request.body.type or "unknown"
    
    if event_type == "connect" then
        return handle_connect(request)
    elseif event_type == "disconnect" then
        return handle_disconnect(request)
    elseif event_type == "message" then
        return handle_message(request)
    else
        return {
            type = "error",
            message = "Unknown event type: " .. event_type
        }
    end
end

-- Export the handler
return {
    handle = handle_request
}

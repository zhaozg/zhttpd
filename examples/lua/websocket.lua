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
--   path = "/ws" or "/graphql/ws",
--   data = <message data (for message type)>
-- }
--
-- The handler should return a response table that will be serialized to JSON
-- and sent back to the client.
--
-- For GraphQL subscriptions (/graphql/ws), messages follow the graphql-ws protocol:
-- https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md

-- Store active connections
local connections = {}

-- Store active GraphQL subscriptions
local subscriptions = {}

-- Handle new connection
local function handle_connect(request)
    local conn_id = request.connection_id
    connections[conn_id] = {
        id = conn_id,
        path = request.path,
        connected_at = os.time()
    }
    
    -- For GraphQL WebSocket, the client should send connection_init
    if request.path == "/graphql/ws" then
        return {
            type = "connection_ack"
        }
    end
    
    return {
        type = "connected",
        message = "Welcome to zhttpd WebSocket!",
        connection_id = conn_id
    }
end

-- Handle client disconnect
local function handle_disconnect(request)
    local conn_id = request.connection_id
    
    -- Clean up subscriptions for this connection
    if subscriptions[conn_id] then
        subscriptions[conn_id] = nil
    end
    
    -- Remove connection
    connections[conn_id] = nil
    
    return {
        type = "disconnected",
        connection_id = conn_id
    }
end

-- Parse JSON string (simple parser for basic cases)
local function parse_json(str)
    -- Try to use a simple pattern-based approach for common cases
    -- This is a simplified parser - for production use cjson
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

-- Handle GraphQL WebSocket protocol messages
local function handle_graphql_message(request, parsed)
    local msg_type = parsed.type
    local conn_id = request.connection_id
    
    if msg_type == "connection_init" then
        return {
            type = "connection_ack"
        }
    elseif msg_type == "ping" then
        return {
            type = "pong"
        }
    elseif msg_type == "subscribe" then
        -- Store the subscription
        local sub_id = parsed.id or "default"
        if not subscriptions[conn_id] then
            subscriptions[conn_id] = {}
        end
        subscriptions[conn_id][sub_id] = {
            id = sub_id,
            payload = parsed.payload,
            started_at = os.time()
        }
        
        -- Send initial data (demo - in real implementation, this would query data)
        return {
            id = sub_id,
            type = "next",
            payload = {
                data = {
                    subscription_started = true,
                    message = "Subscription " .. sub_id .. " started",
                    timestamp = os.time()
                }
            }
        }
    elseif msg_type == "complete" then
        -- Complete the subscription
        local sub_id = parsed.id or "default"
        if subscriptions[conn_id] then
            subscriptions[conn_id][sub_id] = nil
        end
        return {
            id = sub_id,
            type = "complete"
        }
    else
        return {
            type = "error",
            payload = {
                message = "Unknown message type: " .. (msg_type or "nil")
            }
        }
    end
end

-- Handle incoming message
local function handle_message(request)
    local data = request.data or ""
    local path = request.path
    
    -- Check if this is a GraphQL WebSocket connection
    if path == "/graphql/ws" then
        local parsed = parse_json(data)
        return handle_graphql_message(request, parsed)
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

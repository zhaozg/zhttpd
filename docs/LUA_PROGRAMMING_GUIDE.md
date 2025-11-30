# Lua Programming Guide for zhttpd

This guide provides comprehensive documentation for developing Lua scripts in zhttpd, including the handler API, request/response handling, and best practices.

## Table of Contents

1. [Overview](#overview)
2. [Handler Signature](#handler-signature)
3. [Request API](#request-api)
4. [Response API](#response-api)
5. [Context Data Storage](#context-data-storage)
6. [Working with JSON](#working-with-json)
7. [Examples](#examples)
8. [Best Practices](#best-practices)

## Overview

zhttpd provides Lua scripting capabilities for dynamic content generation and API handling. The Lua integration is based on [ziglua](https://github.com/natecraddock/ziglua) and supports both Lua 5.4 and LuaJIT.

### Script Structure

All Lua scripts must export a table with a `handle` function:

```lua
function handle(request, response, context)
    -- Handle the request
    return { status = "success", message = "Hello!" }
end

return { handle = handle }
```

The return value is automatically serialized to JSON and sent as the response body.

### Script Location

Scripts are loaded from the configured `lua_scripts_dir` (default: `./examples/lua`). The script name is derived from the URL path:

| URL Path | Script File |
|----------|-------------|
| `/api/test` | `test.lua` |
| `/api/users` | `users.lua` |
| `/api/users/123` | `users.lua` |
| `/api/todo` | `todo.lua` |

## Handler Signature

The handler function receives three separate parameters for clarity:

```lua
function handle(request, response, context)
    -- request: Object for reading request data
    -- response: Object for setting response properties
    -- context: A Lua table for per-request data storage
    
    return { status = "success" }
end
```

### Why This Signature?

1. **Clear Separation**: Each parameter has a distinct purpose
2. **Direct httpz Access**: Methods directly call the httpz library for better performance
3. **Response Control**: Set status codes, headers, and content types from Lua
4. **Per-Request Storage**: Store data that persists for the duration of the request
5. **Intuitive API**: Method-based access (`:method()`) is clean and easy to use

## Request API

The `request` object provides methods to access request data:

### `request:method()`

Returns the HTTP method as a string.

```lua
local method = request:method()  -- "GET", "POST", "PUT", "DELETE", etc.
```

### `request:path()`

Returns the request path (without query string).

```lua
local path = request:path()  -- "/api/users"
```

### `request:url()`

Returns the full URL including query string.

```lua
local url = request:url()  -- "/api/users?page=1&limit=10"
```

### `request:header(name)`

Returns the value of a specific header, or `nil` if not found.

```lua
local content_type = request:header("content-type")
local auth = request:header("authorization")

if auth then
    -- Process authentication
end
```

### `request:headers()`

Returns all headers as a Lua table.

```lua
local headers = request:headers()
for name, value in pairs(headers) do
    print(name, value)
end
```

### `request:query(name)`

Returns the value of a specific query parameter, or `nil` if not found.

```lua
local page = request:query("page") or "1"
local limit = request:query("limit") or "10"
local sort = request:query("sort")
```

### `request:query_all()`

Returns all query parameters as a Lua table.

```lua
local params = request:query_all()
-- For /api/users?page=1&sort=name
-- params.page = "1"
-- params.sort = "name"
```

### `request:body()`

Returns the request body. For JSON content, it's automatically parsed into a Lua table. For other content types, returns the raw string.

```lua
local data = request:body()
if data then
    if type(data) == "table" then
        -- Parsed JSON
        local username = data.username
        local email = data.email
    else
        -- Raw string
        process_raw_data(data)
    end
end
```

### `request:body_raw()`

Always returns the request body as a raw string, without JSON parsing.

```lua
local raw = request:body_raw()
-- Always a string (or nil if no body)
```

### `request:param(name)`

Returns a URL path parameter (from route patterns like `/users/:id`).

```lua
-- For route /api/users/:id and URL /api/users/123
local user_id = request:param("id")  -- "123"
```

## Response API

The `response` object provides methods to set response properties:

### `response:status(code)`

Sets the HTTP status code.

```lua
response:status(200)  -- OK
response:status(201)  -- Created
response:status(400)  -- Bad Request
response:status(404)  -- Not Found
response:status(500)  -- Internal Server Error
```

### `response:header(name, value)`

Sets a response header.

```lua
response:header("X-Custom-Header", "custom-value")
response:header("Cache-Control", "no-cache")
response:header("X-Request-ID", request_id)
```

### `response:content_type(type)`

Sets or gets the Content-Type header. Supports common types:

```lua
-- Setter
response:content_type("application/json")
response:content_type("text/html")
response:content_type("text/plain")
response:content_type("text/css")
response:content_type("application/javascript")
response:content_type("application/xml")

-- Getter
local current_type = response:content_type()
```

### `response:body(content)`

Sets or gets the response body directly. 

> **Note:** The return value from your handler is always serialized to JSON and used as the response body. If you set the body via `response:body()`, it will be overwritten by the JSON serialization of your return value. To use a custom body, return `nil` from your handler.

```lua
response:content_type("text/html")
response:body("<html><body><h1>Hello!</h1></body></html>")
-- Return nil to prevent JSON serialization from overwriting the body
```

## Context Data Storage

The `context` parameter is a Lua table that persists for the duration of the request. Use it to:

- Store intermediate computation results
- Pass data between different parts of your handler
- Track request metadata

```lua
function handle(request, response, context)
    -- Store data
    context.start_time = os.time()
    context.user_id = nil
    
    -- Process request
    local auth = request:header("authorization")
    if auth then
        context.user_id = validate_auth(auth)
    end
    
    -- Use stored data
    local result = {
        user_id = context.user_id,
        processing_time = os.time() - context.start_time
    }
    
    return result
end
```

## Working with JSON

zhttpd provides a built-in `json` module for JSON encoding and decoding.

### Encoding to JSON

```lua
local data = {
    name = "John",
    age = 30,
    active = true,
    roles = {"admin", "user"}
}

local json_str = json.encode(data)
-- {"name":"John","age":30,"active":true,"roles":["admin","user"]}
```

### Decoding from JSON

```lua
local json_str = '{"status":"ok","count":42}'
local data = json.decode(json_str)

print(data.status)  -- "ok"
print(data.count)   -- 42
```

### Handling NULL

```lua
-- json.null represents JSON null
local data = json.decode('{"value":null}')
print(data.value == nil)  -- true (json.null == nil)
```

### Error Handling

```lua
local function safe_decode(json_str)
    local success, result = pcall(function()
        return json.decode(json_str)
    end)
    
    if success then
        return result
    else
        return nil, "Invalid JSON"
    end
end

local data, err = safe_decode(potentially_invalid_json)
if err then
    response:status(400)
    return { error = err }
end
```

## Examples

### Basic API Handler

```lua
function handle(request, response, context)
    local method = request:method()
    
    if method == "GET" then
        return { users = get_all_users() }
    elseif method == "POST" then
        local data = request:body()
        local user = create_user(data)
        response:status(201)
        return { user = user }
    else
        response:status(405)
        return { error = "Method not allowed" }
    end
end

return { handle = handle }
```

### RESTful User API

```lua
local users = {}
local next_id = 1

function handle(request, response, context)
    local method = request:method()
    local path = request:path()
    
    -- GET /api/users - List all users
    if method == "GET" and path == "/api/users" then
        return { users = table_values(users) }
    end
    
    -- GET /api/users/:id - Get specific user
    local id = path:match("/api/users/(%d+)$")
    if method == "GET" and id then
        local user = users[tonumber(id)]
        if user then
            return user
        else
            response:status(404)
            return { error = "User not found" }
        end
    end
    
    -- POST /api/users - Create user
    if method == "POST" and path == "/api/users" then
        local data = request:body()
        if not data or not data.name then
            response:status(400)
            return { error = "Name is required" }
        end
        
        local user = {
            id = next_id,
            name = data.name,
            email = data.email,
            created_at = os.time()
        }
        users[next_id] = user
        next_id = next_id + 1
        
        response:status(201)
        return user
    end
    
    response:status(404)
    return { error = "Route not found" }
end

function table_values(t)
    local values = {}
    for _, v in pairs(t) do
        table.insert(values, v)
    end
    return values
end

return { handle = handle }
```

### Authentication Example

```lua
function handle(request, response, context)
    -- Check for authentication token
    local auth_header = request:header("authorization")
    
    if not auth_header then
        response:status(401)
        response:header("WWW-Authenticate", "Bearer")
        return { error = "Authentication required" }
    end
    
    -- Extract and validate token
    local token = auth_header:match("Bearer%s+(.+)")
    if not token then
        response:status(401)
        return { error = "Invalid authorization format" }
    end
    
    local user = validate_token(token)
    if not user then
        response:status(403)
        return { error = "Invalid or expired token" }
    end
    
    -- Store user in context for later use
    context.user = user
    
    -- Process authenticated request
    return process_request(request, response, context)
end

function validate_token(token)
    -- Demo validation - replace with real logic
    if token:match("^valid_") then
        return { id = 1, name = "John" }
    end
    return nil
end

function process_request(request, response, context)
    return {
        status = "success",
        user = context.user
    }
end

return { handle = handle }
```

### Custom Headers and Status

```lua
function handle(request, response, context)
    -- Set custom headers
    response:header("X-API-Version", "2.0")
    response:header("X-Request-ID", generate_id())
    
    -- Conditional status
    local data = request:body()
    if not data then
        response:status(400)
        return { error = "Request body required" }
    end
    
    -- Process and return
    local result = process(data)
    
    if result.is_new then
        response:status(201)  -- Created
    else
        response:status(200)  -- OK
    end
    
    return result
end

function generate_id()
    return string.format("%x%x", os.time(), math.random(1000000))
end

return { handle = handle }
```

## Best Practices

### 1. Use the Three-Parameter Signature

Use the clear three-parameter handler signature:

```lua
-- Good: Clear separation of concerns
function handle(request, response, context)
    local method = request:method()
    response:status(200)
    context.processed = true
end
```

### 2. Validate Input

Always validate request data before processing:

```lua
function handle(request, response, context)
    local data = request:body()
    
    if not data then
        response:status(400)
        return { error = "Request body required" }
    end
    
    if not data.username or #data.username == 0 then
        response:status(400)
        return { error = "Username is required" }
    end
    
    if #data.username > 100 then
        response:status(400)
        return { error = "Username too long" }
    end
    
    -- Process validated data
end
```

### 3. Handle Errors Gracefully

Use pcall for operations that might fail:

```lua
function handle(request, response, context)
    local success, result = pcall(function()
        return process_request(request, response, context)
    end)
    
    if success then
        return result
    else
        response:status(500)
        return { error = "Internal server error" }
    end
end
```

### 4. Use Appropriate Status Codes

```lua
response:status(200)  -- OK (default)
response:status(201)  -- Created (after POST)
response:status(204)  -- No Content (after DELETE)
response:status(400)  -- Bad Request (validation error)
response:status(401)  -- Unauthorized (no auth)
response:status(403)  -- Forbidden (no permission)
response:status(404)  -- Not Found
response:status(500)  -- Internal Server Error
```

### 5. Set Content-Type for Non-JSON Responses

```lua
-- For HTML responses
response:content_type("text/html")
response:body("<html>...</html>")
-- Return nil to prevent JSON serialization from overwriting body

-- For plain text
response:content_type("text/plain")
response:body("Hello, World!")
```

### 6. Avoid Global State

Use `context` instead of global variables for request-specific data:

```lua
-- Bad: Global state can leak between requests
local request_start = nil

function handle(request, response, context)
    request_start = os.time()
    -- ...
end

-- Good: Per-request data
function handle(request, response, context)
    context.request_start = os.time()
    -- ...
end
```

### 7. Keep Scripts Focused

One script should handle one API resource. Use route patterns for sub-resources:

```
users.lua     -> /api/users, /api/users/:id
todo.lua      -> /api/todo, /api/todo/:id
settings.lua  -> /api/settings
```

---

## See Also

- [Lua C Module Integration Guide](LUA_C_MODULES.md) - json module details
- [Security Guide](SECURITY.md) - Security considerations
- [Architecture Guide](ARCHITECTURE.md) - System architecture

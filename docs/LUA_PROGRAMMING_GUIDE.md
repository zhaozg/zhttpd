# Lua Programming Guide for zhttpd

This guide provides comprehensive documentation for developing Lua scripts in zhttpd, including the Per-Request Context API, request/response handling, and best practices.

## Table of Contents

1. [Overview](#overview)
2. [Per-Request Context API](#per-request-context-api)
3. [Request API](#request-api)
4. [Response API](#response-api)
5. [Per-Request Data Storage](#per-request-data-storage)
6. [Working with JSON](#working-with-json)
7. [Examples](#examples)
8. [Best Practices](#best-practices)
9. [Migration from Legacy API](#migration-from-legacy-api)

## Overview

zhttpd provides Lua scripting capabilities for dynamic content generation and API handling. The Lua integration is based on [ziglua](https://github.com/natecraddock/ziglua) and supports both Lua 5.4 and LuaJIT.

### Script Structure

All Lua scripts must export a table with a `handle` function:

```lua
function handle(ctx)
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

## Per-Request Context API

The preferred way to handle requests is using the Per-Request Context API. The `handle` function receives a `ctx` object with three components:

```lua
function handle(ctx)
    -- ctx.req: Request object for reading request data
    -- ctx.res: Response object for setting response properties
    -- ctx.data: Per-request data storage (Lua table)
    
    return { status = "success" }
end
```

### Why Use Context API?

1. **Direct httpz Access**: Methods directly call the httpz library for better performance
2. **Response Control**: Set status codes, headers, and content types from Lua
3. **Per-Request Storage**: Store data that persists for the duration of the request
4. **Cleaner API**: Method-based access (`:method()`) is more intuitive

## Request API

The `ctx.req` object provides methods to access request data:

### `ctx.req:method()`

Returns the HTTP method as a string.

```lua
local method = ctx.req:method()  -- "GET", "POST", "PUT", "DELETE", etc.
```

### `ctx.req:path()`

Returns the request path (without query string).

```lua
local path = ctx.req:path()  -- "/api/users"
```

### `ctx.req:url()`

Returns the full URL including query string.

```lua
local url = ctx.req:url()  -- "/api/users?page=1&limit=10"
```

### `ctx.req:header(name)`

Returns the value of a specific header, or `nil` if not found.

```lua
local content_type = ctx.req:header("content-type")
local auth = ctx.req:header("authorization")

if auth then
    -- Process authentication
end
```

### `ctx.req:headers()`

Returns all headers as a Lua table.

```lua
local headers = ctx.req:headers()
for name, value in pairs(headers) do
    print(name, value)
end
```

### `ctx.req:query(name)`

Returns the value of a specific query parameter, or `nil` if not found.

```lua
local page = ctx.req:query("page") or "1"
local limit = ctx.req:query("limit") or "10"
local sort = ctx.req:query("sort")
```

### `ctx.req:query_all()`

Returns all query parameters as a Lua table.

```lua
local params = ctx.req:query_all()
-- For /api/users?page=1&sort=name
-- params.page = "1"
-- params.sort = "name"
```

### `ctx.req:body()`

Returns the request body. For JSON content, it's automatically parsed into a Lua table. For other content types, returns the raw string.

```lua
local data = ctx.req:body()
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

### `ctx.req:body_raw()`

Always returns the request body as a raw string, without JSON parsing.

```lua
local raw = ctx.req:body_raw()
-- Always a string (or nil if no body)
```

### `ctx.req:param(name)`

Returns a URL path parameter (from route patterns like `/users/:id`).

```lua
-- For route /api/users/:id and URL /api/users/123
local user_id = ctx.req:param("id")  -- "123"
```

## Response API

The `ctx.res` object provides methods to set response properties:

### `ctx.res:status(code)`

Sets the HTTP status code.

```lua
ctx.res:status(200)  -- OK
ctx.res:status(201)  -- Created
ctx.res:status(400)  -- Bad Request
ctx.res:status(404)  -- Not Found
ctx.res:status(500)  -- Internal Server Error
```

### `ctx.res:header(name, value)`

Sets a response header.

```lua
ctx.res:header("X-Custom-Header", "custom-value")
ctx.res:header("Cache-Control", "no-cache")
ctx.res:header("X-Request-ID", request_id)
```

### `ctx.res:content_type(type)`

Sets the Content-Type header. Supports common types:

```lua
ctx.res:content_type("application/json")
ctx.res:content_type("text/html")
ctx.res:content_type("text/plain")
ctx.res:content_type("text/css")
ctx.res:content_type("application/javascript")
ctx.res:content_type("application/xml")
```

### `ctx.res:body(content)`

Sets the response body directly. Useful for non-JSON responses.

```lua
ctx.res:content_type("text/html")
ctx.res:body("<html><body><h1>Hello!</h1></body></html>")
return nil  -- Return nil when using res:body()
```

## Per-Request Data Storage

The `ctx.data` table is a Lua table that persists for the duration of the request. Use it to:

- Store intermediate computation results
- Pass data between different parts of your handler
- Track request metadata

```lua
function handle(ctx)
    -- Store data
    ctx.data.start_time = os.time()
    ctx.data.user_id = nil
    
    -- Process request
    local auth = ctx.req:header("authorization")
    if auth then
        ctx.data.user_id = validate_auth(auth)
    end
    
    -- Use stored data
    local response = {
        user_id = ctx.data.user_id,
        processing_time = os.time() - ctx.data.start_time
    }
    
    return response
end
```

## Working with JSON

zhttpd provides a built-in `cjson` module compatible with the popular lua-cjson library.

### Encoding to JSON

```lua
local data = {
    name = "John",
    age = 30,
    active = true,
    roles = {"admin", "user"}
}

local json_str = cjson.encode(data)
-- {"name":"John","age":30,"active":true,"roles":["admin","user"]}
```

### Decoding from JSON

```lua
local json_str = '{"status":"ok","count":42}'
local data = cjson.decode(json_str)

print(data.status)  -- "ok"
print(data.count)   -- 42
```

### Handling NULL

```lua
-- cjson.null represents JSON null
local data = cjson.decode('{"value":null}')
print(data.value == nil)  -- true (cjson.null == nil)
```

### Error Handling

```lua
local function safe_decode(json_str)
    local success, result = pcall(function()
        return cjson.decode(json_str)
    end)
    
    if success then
        return result
    else
        return nil, "Invalid JSON"
    end
end

local data, err = safe_decode(potentially_invalid_json)
if err then
    ctx.res:status(400)
    return { error = err }
end
```

## Examples

### Basic API Handler

```lua
function handle(ctx)
    local method = ctx.req:method()
    
    if method == "GET" then
        return { users = get_all_users() }
    elseif method == "POST" then
        local data = ctx.req:body()
        local user = create_user(data)
        ctx.res:status(201)
        return { user = user }
    else
        ctx.res:status(405)
        return { error = "Method not allowed" }
    end
end

return { handle = handle }
```

### RESTful User API

```lua
local users = {}
local next_id = 1

function handle(ctx)
    local method = ctx.req:method()
    local path = ctx.req:path()
    
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
            ctx.res:status(404)
            return { error = "User not found" }
        end
    end
    
    -- POST /api/users - Create user
    if method == "POST" and path == "/api/users" then
        local data = ctx.req:body()
        if not data or not data.name then
            ctx.res:status(400)
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
        
        ctx.res:status(201)
        return user
    end
    
    ctx.res:status(404)
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
function handle(ctx)
    -- Check for authentication token
    local auth_header = ctx.req:header("authorization")
    
    if not auth_header then
        ctx.res:status(401)
        ctx.res:header("WWW-Authenticate", "Bearer")
        return { error = "Authentication required" }
    end
    
    -- Extract and validate token
    local token = auth_header:match("Bearer%s+(.+)")
    if not token then
        ctx.res:status(401)
        return { error = "Invalid authorization format" }
    end
    
    local user = validate_token(token)
    if not user then
        ctx.res:status(403)
        return { error = "Invalid or expired token" }
    end
    
    -- Store user in context for later use
    ctx.data.user = user
    
    -- Process authenticated request
    return process_request(ctx)
end

function validate_token(token)
    -- Demo validation - replace with real logic
    if token:match("^valid_") then
        return { id = 1, name = "John" }
    end
    return nil
end

function process_request(ctx)
    return {
        status = "success",
        user = ctx.data.user
    }
end

return { handle = handle }
```

### Custom Headers and Status

```lua
function handle(ctx)
    -- Set custom headers
    ctx.res:header("X-API-Version", "2.0")
    ctx.res:header("X-Request-ID", generate_id())
    
    -- Conditional status
    local data = ctx.req:body()
    if not data then
        ctx.res:status(400)
        return { error = "Request body required" }
    end
    
    -- Process and return
    local result = process(data)
    
    if result.is_new then
        ctx.res:status(201)  -- Created
    else
        ctx.res:status(200)  -- OK
    end
    
    return result
end

function generate_id()
    return string.format("%x%x", os.time(), math.random(1000000))
end

return { handle = handle }
```

## Best Practices

### 1. Use Context API

Prefer the new context-based API over the legacy request table:

```lua
-- Good
function handle(ctx)
    local method = ctx.req:method()
end

-- Legacy (avoid for new code)
function handle(request)
    local method = request.method
end
```

### 2. Validate Input

Always validate request data before processing:

```lua
function handle(ctx)
    local data = ctx.req:body()
    
    if not data then
        ctx.res:status(400)
        return { error = "Request body required" }
    end
    
    if not data.username or #data.username == 0 then
        ctx.res:status(400)
        return { error = "Username is required" }
    end
    
    if #data.username > 100 then
        ctx.res:status(400)
        return { error = "Username too long" }
    end
    
    -- Process validated data
end
```

### 3. Handle Errors Gracefully

Use pcall for operations that might fail:

```lua
function handle(ctx)
    local success, result = pcall(function()
        return process_request(ctx)
    end)
    
    if success then
        return result
    else
        ctx.res:status(500)
        return { error = "Internal server error" }
    end
end
```

### 4. Use Appropriate Status Codes

```lua
ctx.res:status(200)  -- OK (default)
ctx.res:status(201)  -- Created (after POST)
ctx.res:status(204)  -- No Content (after DELETE)
ctx.res:status(400)  -- Bad Request (validation error)
ctx.res:status(401)  -- Unauthorized (no auth)
ctx.res:status(403)  -- Forbidden (no permission)
ctx.res:status(404)  -- Not Found
ctx.res:status(500)  -- Internal Server Error
```

### 5. Set Content-Type for Non-JSON Responses

```lua
-- For HTML responses
ctx.res:content_type("text/html")
ctx.res:body("<html>...</html>")
return nil

-- For plain text
ctx.res:content_type("text/plain")
ctx.res:body("Hello, World!")
return nil
```

### 6. Avoid Global State

Use `ctx.data` instead of global variables for request-specific data:

```lua
-- Bad: Global state can leak between requests
local request_start = nil

function handle(ctx)
    request_start = os.time()
    -- ...
end

-- Good: Per-request data
function handle(ctx)
    ctx.data.request_start = os.time()
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

## Migration from Legacy API

If you have scripts using the legacy request table API, you can migrate to the context API:

### Legacy Style

```lua
function handle(request)
    local method = request.method
    local path = request.path
    local content_type = request.headers["content-type"]
    local page = request.query["page"]
    local data = request.body
    
    return { status = "success" }
end

return { handle = handle }
```

### New Context Style

```lua
function handle(ctx)
    local method = ctx.req:method()
    local path = ctx.req:path()
    local content_type = ctx.req:header("content-type")
    local page = ctx.req:query("page")
    local data = ctx.req:body()
    
    -- New capabilities:
    ctx.res:status(200)
    ctx.res:header("X-Custom", "value")
    ctx.data.user_id = "123"
    
    return { status = "success" }
end

return { handle = handle }
```

### Supporting Both Styles

For backward compatibility, you can detect the calling convention:

```lua
function handle(ctx_or_request)
    if ctx_or_request.req then
        -- New context style
        return handle_context(ctx_or_request)
    else
        -- Legacy style
        return handle_legacy(ctx_or_request)
    end
end

return { handle = handle }
```

---

## See Also

- [Lua C Module Integration Guide](LUA_C_MODULES.md) - cjson module details
- [Security Guide](SECURITY.md) - Security considerations
- [Architecture Guide](ARCHITECTURE.md) - System architecture

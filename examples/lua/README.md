# Lua Dynamic Page Examples

This directory contains example Lua scripts that demonstrate dynamic content generation with zhttpd.

## Thread Safety

The Lua handler uses a **pool of Lua states** to ensure thread-safety:
- Each request gets its own Lua state from the pool
- Lua states are NOT thread-safe, so we use mutex-protected pooling
- After handling a request, the state is cleared and returned to the pool
- This allows efficient multi-threaded, multi-connection concurrent processing

## Request Structure

Each Lua handler receives a request table with the following structure:

```lua
request = {
    method = "GET" or "POST",  -- HTTP method
    path = "/api/example",     -- Full request path
    body = { ... }             -- Parsed JSON body (for POST requests)
}
```

## Response Structure

Lua handlers should return a table that will be converted to JSON:

```lua
return {
    status = "success",  -- or "error"
    data = { ... },      -- Response data
    message = "...",     -- Optional message
    timestamp = os.time()
}
```

## Examples

### 1. test.lua - Simple Echo Example

Basic example that echoes back the request data.

**Usage:**
```bash
# POST request
curl -X POST http://localhost:8080/api/test \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello from client"}'
```

### 2. users.lua - User Management API

Demonstrates simple CRUD operations for user management.

**Usage:**
```bash
# List all users (GET)
curl http://localhost:8080/api/users

# Get specific user (GET)
curl http://localhost:8080/api/users/1

# Create user (POST)
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "email": "john@example.com"}'
```

### 3. todo.lua - Complete Todo List API

**Full-featured example** demonstrating GET and POST methods with proper routing.

**Features:**
- Create new todos
- List all todos
- Get specific todo by ID
- Mark todos as completed
- Proper error handling
- Thread-safe execution (each state has its own data)

**API Endpoints:**

```bash
# Create a new todo (POST)
curl -X POST http://localhost:8080/api/todo \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Learn Zig",
    "description": "Complete the Zig tutorial"
  }'

# List all todos (GET)
curl http://localhost:8080/api/todo

# Get specific todo (GET)
curl http://localhost:8080/api/todo/1

# Mark todo as completed (POST)
curl -X POST http://localhost:8080/api/todo/1/complete \
  -H "Content-Type: application/json"
```

**Response Examples:**

Success response:
```json
{
  "status": "success",
  "data": {
    "id": 1,
    "title": "Learn Zig",
    "description": "Complete the Zig tutorial",
    "completed": false,
    "created_at": 1732601234
  },
  "message": "Todo created successfully",
  "timestamp": 1732601234
}
```

Error response:
```json
{
  "status": "error",
  "data": null,
  "message": "Todo not found",
  "timestamp": 1732601234
}
```

## Creating Your Own Lua Handler

1. Create a new `.lua` file in this directory
2. Implement a `handle_request(request)` function
3. Return a module table with the handler:

```lua
function handle_request(request)
    local method = request.method
    local path = request.path
    local body = request.body
    
    -- Your logic here
    if method == "GET" then
        return { status = "success", data = { message = "GET response" } }
    elseif method == "POST" then
        return { status = "success", data = { received = body } }
    end
end

return {
    handle = handle_request
}
```

4. Access it at `http://localhost:8080/api/your-file-name`

## Performance Considerations

1. **Lua State Pooling**: States are reused across requests for efficiency
2. **Memory Management**: Each state's stack is cleared after use
3. **Concurrency**: Pool size can be adjusted in `lua.zig` (default: 4 states)
4. **Data Persistence**: In-memory data is per-state. For shared data, use external storage

## Security Notes

1. **Path Traversal Protection**: Script names cannot contain `..`, `/`, or `\`
2. **JSON Validation**: Request bodies are validated before passing to Lua
3. **Error Handling**: Lua errors are caught and returned as JSON error responses
4. **Sandboxing**: Standard Lua libraries are available, but file system access is limited

## Advanced Topics

### Shared State Across Requests

Since each Lua state is isolated, in-memory data is not shared between requests by default. For shared state:

1. Use external storage (database, Redis, etc.)
2. Implement inter-state communication via Zig
3. Use file-based storage (not recommended for high concurrency)

### Custom Lua Libraries

You can extend the Lua environment by modifying `lua.zig`:

```zig
// In LuaStatePool.init()
lua.openLibs();
// Register custom libraries here
```

### Performance Tuning

Adjust the pool size based on your concurrency needs:

```zig
// In lua.zig, LuaHandler.init()
const pool = try LuaStatePool.init(allocator, 8); // Increase pool size
```

## Troubleshooting

**Script not found:**
- Ensure the `.lua` file is in the `lua_scripts_dir` configured in zhttpd.yaml
- Check file permissions

**JSON parse errors:**
- Validate your request body is valid JSON
- Use `Content-Type: application/json` header

**Lua execution errors:**
- Check server logs for detailed error messages
- Ensure your script returns a table with a `handle` function

**Concurrency issues:**
- The Lua state pool handles thread-safety automatically
- Each request gets its own isolated state
- No need for manual locking in Lua code

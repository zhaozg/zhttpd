# Lua Dynamic Page Examples

This directory contains example Lua scripts that demonstrate dynamic content generation with zhttpd.

## Phase 1 Enhanced Features

zhttpd now includes enhanced Lua integration with the following features:

### Complex Request Data Structures (luvit/Node.js Style)

Lua scripts now receive full request information including:
- HTTP headers
- Query parameters  
- Request body
- Method and path

### Script Hot-Reloading

Scripts are automatically reloaded when modified (with `reload: auto` config):
- No server restart required
- File modification time is checked on each request
- Bytecode cache is invalidated automatically

### Script Caching and Precompilation

For improved performance:
- Scripts are cached in memory
- Bytecode is precompiled when possible
- Cache can be cleared programmatically

### Sandboxing and Resource Limits

For security and stability (configurable via `zhttpd.yaml`):
- Dangerous functions are disabled (`io`, `debug`, `os.execute`, etc.)
- Instruction count limits prevent infinite loops
- `lua_sandbox_enabled: true` (safe default)
- `lua_max_instructions: 100000` (safe default)

## Thread Safety

Each HTTP worker thread has its own **dedicated Lua VM** via thread-local storage:
- No mutex contention for better performance
- Each worker thread processes requests with its own Lua state
- Lua states are automatically initialized on first use per thread
- This allows efficient multi-threaded, multi-connection concurrent processing

## Request Structure

Each Lua handler receives a request table with the following structure (luvit/Node.js style):

```lua
request = {
    method = "GET" or "POST",       -- HTTP method
    path = "/api/example",          -- Full request path
    url = "/api/example",           -- Alias for path (luvit style)
    headers = {                     -- HTTP request headers
        ["content-type"] = "application/json",
        ["user-agent"] = "curl/7.68.0",
        ["accept"] = "*/*",
        ...
    },
    query = {                       -- Query string parameters
        page = "1",
        limit = "10",
        ...
    },
    body = { ... }                  -- Parsed JSON body (for POST/PUT requests)
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

### 1. test.lua - Simple Echo Example with Headers/Query

Demonstrates the full request structure including headers and query parameters.

**Usage:**
```bash
# GET request with query parameters
curl "http://localhost:8080/api/test?page=2&limit=20"

# POST request with headers
curl -X POST http://localhost:8080/api/test \
  -H "Content-Type: application/json" \
  -H "X-Custom-Header: test-value" \
  -d '{"message": "Hello from client"}'
```

**Response includes request info:**
```json
{
  "status": "success",
  "message": "Hello from Lua!",
  "request_info": {
    "method": "GET",
    "path": "/api/test",
    "content_type": "application/json",
    "user_agent": "curl/7.68.0",
    "page": "2",
    "limit": "20"
  }
}
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

### 4. auth.lua - Authentication Example

Demonstrates JWT/OAuth token validation for protected endpoints.

**Features:**
- Token validation (demo format: `zhttpd_<user_id>_<role>`)
- Session management
- Role-based access control

## Creating Your Own Lua Handler

1. Create a new `.lua` file in this directory
2. Implement a `handle_request(request)` function
3. Return a module table with the handler:

```lua
function handle_request(request)
    local method = request.method
    local path = request.path
    local body = request.body
    
    -- Access headers (luvit/Node.js style)
    local auth_header = request.headers and request.headers["authorization"] or nil
    
    -- Access query parameters
    local page = request.query and request.query["page"] or "1"
    
    -- Your logic here
    if method == "GET" then
        return { 
            status = "success", 
            data = { 
                message = "GET response",
                page = page
            } 
        }
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

1. **Thread-Local Lua VMs**: Each worker thread has its own Lua VM (no mutex contention)
2. **Memory Management**: Each state's stack is cleared after use
3. **Concurrency**: One Lua VM per worker thread (controlled by `thread_pool_size`)
4. **Data Persistence**: In-memory data is per-thread. For shared data, use external storage
5. **Bytecode Caching**: Scripts are precompiled for faster execution

## Security Notes

1. **Path Traversal Protection**: Script names cannot contain `..`, `/`, or `\`
2. **JSON Validation**: Request bodies are validated before passing to Lua
3. **Error Handling**: Lua errors are caught and returned as JSON error responses
4. **Sandboxing**: The following are disabled by default:
   - `io` library (file I/O)
   - `debug` library (can escape sandbox)
   - `os.execute`, `os.exit`, `os.remove`, `os.rename`, `os.getenv`, `os.tmpname`
   - `loadfile`, `dofile` (arbitrary file execution)
5. **Instruction Limits**: Scripts are limited to 100,000 instructions by default

## Configuration

Sandbox settings can be configured via `zhttpd.yaml`:

```yaml
# Lua sandbox configuration (safe defaults)
lua_sandbox_enabled: true      # Enable sandbox restrictions (default: true)
lua_max_instructions: 100000   # Max instructions per execution (0 = unlimited, default: 100000)
```

Or programmatically via `SandboxConfig`:

```zig
const config = SandboxConfig{
    .max_instructions = 50_000,    // Instruction limit (0 = unlimited)
    .max_memory = 0,               // Memory limit in bytes (not yet implemented)
    .enable_sandbox = true,        // Enable sandboxing
};
```

## Advanced Topics

### Thread-Local Lua VMs

Each HTTP worker thread has its own dedicated Lua VM via thread-local storage:

- No mutex contention for better performance
- Each worker processes requests with its own Lua state
- Lua states are automatically cleaned up when threads exit

### Shared State Across Requests

Since each Lua state is isolated, in-memory data is not shared between requests by default. For shared state:

1. Use external storage (database, Redis, etc.)
2. Implement inter-state communication via Zig
3. Use file-based storage (not recommended for high concurrency)

### Custom Lua Libraries

You can extend the Lua environment by modifying `lua.zig`:

```zig
// In ThreadLocalLua.init()
lua.openLibs();
// Register custom libraries here
```

### Performance Tuning

Each HTTP worker thread automatically gets its own Lua VM:

- Thread-local storage eliminates mutex contention
- No pool management overhead
- Configure `thread_pool_size` in zhttpd.yaml to adjust the number of worker threads

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

**Instruction limit exceeded:**
- Your script may have an infinite loop
- Increase `lua_max_instructions` in zhttpd.yaml if needed
- Optimize your Lua code

**Concurrency issues:**
- The Lua state pool handles thread-safety automatically
- Each request gets its own isolated state
- No need for manual locking in Lua code

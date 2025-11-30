# Lua C Module Integration Guide

This guide explains how to use Lua modules in zhttpd, including the built-in json module and considerations for external C modules.

## Overview

zhttpd supports two approaches for Lua module integration:

1. **Built-in Modules** (Recommended): Modules implemented in Zig and exposed to Lua
2. **External C Modules**: Traditional Lua C modules (requires disabling sandbox)

## Built-in json Module

zhttpd includes a built-in json module that provides JSON encoding and decoding capabilities. This module is implemented in Zig and is available by default.

### API Reference

#### `json.encode(value)`

Converts a Lua value to a JSON string.

**Parameters:**
- `value`: Any Lua value (table, string, number, boolean, nil)

**Returns:**
- A JSON string representation of the value

**Example:**
```lua
local data = {
    name = "John",
    age = 30,
    active = true,
    scores = {100, 95, 87}
}

local json_str = json.encode(data)
-- Result: {"name":"John","age":30,"active":true,"scores":[100,95,87]}
```

#### `json.decode(json_string)`

Parses a JSON string and returns the corresponding Lua value.

**Parameters:**
- `json_string`: A valid JSON string

**Returns:**
- The Lua value represented by the JSON

**Example:**
```lua
local json_str = '{"status":"ok","count":42,"items":["a","b","c"]}'
local data = json.decode(json_str)

print(data.status)  -- "ok"
print(data.count)   -- 42
print(data.items[1]) -- "a"
```

#### `json.null`

A special value representing JSON null. This is Lua's `nil` value.

### Complete Example

```lua
-- api_handler.lua
function handle_request(request)
    -- Decode incoming JSON body if present
    local body_data = {}
    if request.body then
        body_data = request.body  -- Already parsed by zhttpd
    end
    
    -- Process the request
    local response = {
        status = "success",
        message = "Request processed",
        received = body_data,
        timestamp = os.time()
    }
    
    -- The response will be automatically encoded to JSON
    return response
end

-- You can also use json for intermediate processing
function process_complex_data(request)
    -- Encode a Lua table to JSON string
    local internal_data = {
        operation = "transform",
        input = request.body
    }
    local json_payload = json.encode(internal_data)
    
    -- Decode JSON from an external source
    local external_json = '{"config": {"enabled": true}}'
    local config = json.decode(external_json)
    
    return {
        processed = true,
        config_enabled = config.config.enabled
    }
end

return { handle = handle_request }
```

## Lua Engine Selection

zhttpd supports two Lua engines:

### Lua 5.4 (Default)

Standard Lua 5.4 interpreter. Stable and well-tested.

```bash
# Build with Lua 5.4 (default)
zig build
```

### LuaJIT

LuaJIT provides JIT (Just-In-Time) compilation for significantly improved performance. Based on Lua 5.1.

```bash
# Build with LuaJIT
zig build -Dlua-lang=luajit
```

**Performance Benefits of LuaJIT:**
- JIT compilation for hot code paths
- Optimized FFI for C interop
- Lower memory overhead

**Considerations:**
- Based on Lua 5.1 syntax (some 5.2+ features not available)
- Cross-compilation can be challenging on some platforms

## External C Module Integration

For advanced use cases requiring external C modules (like LuaSec, LuaSocket, etc.), you need to disable the sandbox.

### Configuration

```yaml
# In zhttpd.yaml or config.json
lua_sandbox_enabled: false
```

Or via command-line (planned):
```bash
zhttpd --no-lua-sandbox
```

### Security Warning

⚠️ **Disabling the sandbox allows Lua scripts to:**
- Execute system commands via `os.execute()`
- Read/write files via `io` library
- Load arbitrary C libraries via `package.loadlib()`
- Access environment variables

Only disable the sandbox if:
1. You trust all Lua scripts completely
2. The server is in a controlled environment
3. You understand the security implications

### Building C Modules

External C modules must be compiled as shared libraries (.so/.dll) compatible with your Lua version:

```bash
# For Lua 5.4
gcc -shared -o mymodule.so -fPIC mymodule.c -llua

# For LuaJIT
gcc -shared -o mymodule.so -fPIC mymodule.c -lluajit
```

### Module Search Path

When sandbox is disabled, Lua's `package.path` and `package.cpath` are available:

```lua
-- In your Lua script
package.cpath = package.cpath .. ";./lib/?.so"
local mymodule = require("mymodule")
```

## Best Practices

### 1. Prefer Built-in Modules

The built-in json module is:
- Safe (works within sandbox)
- Fast (implemented in Zig, no FFI overhead)
- Compatible with both Lua 5.4 and LuaJIT

### 2. Use Sandbox for Production

Keep `lua_sandbox_enabled: true` in production unless absolutely necessary.

### 3. Validate All Input

Even with sandboxing, validate all input data:

```lua
function handle_request(request)
    -- Validate required fields
    if not request.body or not request.body.user_id then
        return {status = "error", message = "Missing user_id"}
    end
    
    -- Sanitize string input
    local user_id = tostring(request.body.user_id)
    if #user_id > 100 then
        return {status = "error", message = "user_id too long"}
    end
    
    -- Process validated input
    return process_user(user_id)
end
```

### 4. Handle Errors Gracefully

```lua
function safe_decode(json_str)
    local success, result = pcall(function()
        return json.decode(json_str)
    end)
    
    if success then
        return result
    else
        return nil, "Invalid JSON"
    end
end

function handle_request(request)
    local data, err = safe_decode(request.headers["x-custom-data"] or "{}")
    if err then
        return {status = "error", message = err}
    end
    
    -- Process data...
    return {status = "success", data = data}
end
```

## Supported JSON Types

| Lua Type | JSON Type | Notes |
|----------|-----------|-------|
| `table` (array) | `array` | Tables with consecutive integer keys starting at 1 |
| `table` (object) | `object` | Tables with string keys |
| `string` | `string` | Escape sequences handled automatically |
| `number` | `number` | Integers and floats supported |
| `boolean` | `boolean` | `true`/`false` |
| `nil` | `null` | |

## Performance Tips

1. **Avoid repeated encoding/decoding**: Cache parsed JSON when possible
2. **Use LuaJIT for compute-heavy scripts**: Build with `-Dlua-lang=luajit`
3. **Keep scripts focused**: Prefer multiple small scripts over one large script
4. **Leverage script caching**: zhttpd caches compiled scripts automatically

## Troubleshooting

### "json not found" error

The `json` global should be available automatically. Check that zhttpd is initialized correctly.

### "Lua handler execution failed" error

This can occur due to:
- Instruction limit exceeded (increase `lua_max_instructions`)
- Runtime error in Lua script (check script logic)
- Invalid JSON in request body

### LuaJIT build fails

LuaJIT has specific platform requirements. If the build fails:
1. Try building with standard Lua 5.4 (default)
2. Ensure you have required system libraries (libunwind)
3. Check platform compatibility

## Version Compatibility

| Feature | Lua 5.4 | LuaJIT |
|---------|---------|--------|
| Built-in json | ✅ | ✅ |
| Sandbox | ✅ | ✅ |
| Package library (when sandbox disabled) | ✅ | ✅ |
| FFI | ❌ | ✅ |
| Instruction limit hook | ✅ | ✅ |

---

For more information, see:
- [zhttpd README](../README.md)
- [Lua Documentation](https://www.lua.org/manual/5.4/)
- [LuaJIT Documentation](https://luajit.org/luajit.html)

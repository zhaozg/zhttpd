# Lua C Module Integration Guide

This guide explains how to use Lua modules in zhttpd, including the built-in json and lpeg modules, and considerations for external C modules.

## Overview

zhttpd supports two approaches for Lua module integration:

1. **Built-in Modules** (Recommended): Modules implemented in Zig and exposed to Lua
2. **External C Modules**: Traditional Lua C modules (requires disabling sandbox)

## Built-in Modules

zhttpd includes two powerful built-in modules that are available by default in all Lua scripts:

### json Module

The json module provides JSON encoding and decoding capabilities. This module is implemented using lua-cjson for high performance.

### lpeg Module

The lpeg module provides powerful pattern matching based on Parsing Expression Grammars (PEGs). This is ideal for complex string parsing, validation, and lexical analysis.

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

## Built-in lpeg Module

The lpeg module provides powerful pattern matching capabilities based on Parsing Expression Grammars (PEGs). LPeg is particularly useful for complex string parsing, validation, lexical analysis, and building parsers.

### Why LPeg?

LPeg goes beyond traditional regular expressions by providing:

- **Composable patterns**: Build complex patterns from simple building blocks
- **No backtracking limitations**: PEGs handle nested structures easily
- **Captures**: Extract matched substrings and transform them
- **Grammar support**: Define complete grammars for parsing structured data
- **Better performance**: Often faster than traditional regex for complex patterns

### Basic Pattern Functions

#### `lpeg.P(value)`

Creates a basic pattern. Can accept:
- String: Matches the exact string
- Number: Matches exactly that many characters
- Boolean: `true` always succeeds, `false` always fails

**Example:**
```lua
local pattern = lpeg.P("hello")  -- Matches "hello"
local pos = lpeg.match(pattern, "hello world")  -- Returns 6
```

#### `lpeg.R(range, ...)`

Creates a range pattern that matches any character in the given ranges.

**Example:**
```lua
local digit = lpeg.R("09")        -- Matches any digit
local letter = lpeg.R("az", "AZ")  -- Matches any letter
local alphanumeric = lpeg.R("09", "az", "AZ")
```

#### `lpeg.S(string)`

Creates a set pattern that matches any character in the string.

**Example:**
```lua
local vowel = lpeg.S("aeiouAEIOU")  -- Matches any vowel
local punctuation = lpeg.S(",.!?;:")  -- Matches punctuation
```

#### `lpeg.C(pattern)`

Creates a capture that returns the matched substring.

**Example:**
```lua
local word = lpeg.C(lpeg.R("az")^1)
local result = lpeg.match(word, "hello")  -- Returns "hello"
```

#### `lpeg.match(pattern, subject, init)`

Matches a pattern against a string.

**Parameters:**
- `pattern`: The pattern to match
- `subject`: The string to match against
- `init` (optional): Starting position (default: 1)

**Returns:**
- On success: Position after the match, plus any captures
- On failure: `nil`

### Pattern Operators

LPeg patterns can be combined using operators:

- `p1 * p2`: Sequence - match p1 followed by p2
- `p1 + p2`: Ordered choice - try p1, if it fails try p2
- `p^n`: Exactly n repetitions
- `p^-n`: At most n repetitions
- `p^0`: Zero or more repetitions (*)
- `p^1`: One or more repetitions (+)
- `-p`: Negation - succeeds if p fails (doesn't consume input)
- `#p`: And predicate - succeeds if p succeeds (doesn't consume input)

### Practical Examples

#### Example 1: Parsing Numbers

```lua
local lpeg = lpeg

-- Parse a number with optional sign and decimal point
local sign = lpeg.S("+-")^-1
local digits = lpeg.R("09")^1
local decimal = lpeg.P(".") * digits
local number = lpeg.C(sign * digits * (decimal)^-1)

local result = lpeg.match(number, "-123.456")
-- Returns: "-123.456"
```

#### Example 2: Email Validation

```lua
-- Simple email pattern
local letter = lpeg.R("az", "AZ")
local digit = lpeg.R("09")
local special = lpeg.S("_-.")
local username = (letter + digit + special)^1
local domain = (letter + digit + lpeg.S("-"))^1
local tld = letter^2  -- At least 2 letters

local email = lpeg.C(
    username * 
    lpeg.P("@") * 
    domain * 
    (lpeg.P(".") * domain)^0 * 
    lpeg.P(".") * 
    tld
)

local address = lpeg.match(email, "user@example.com")
-- Returns: "user@example.com"
```

#### Example 3: URL Path Parsing

```lua
-- Extract path segments from a URL path
local slash = lpeg.P("/")
local segment = lpeg.C((1 - slash)^1)
local path = lpeg.Ct(slash * segment * (slash * segment)^0)

local segments = lpeg.match(path, "/api/users/123")
-- Returns: {"api", "users", "123"}
```

#### Example 4: Configuration File Parser

```lua
-- Parse simple KEY=VALUE configuration lines
local space = lpeg.S(" \t")^0
local name = lpeg.C(lpeg.R("az", "AZ", "09", "__")^1)
local eq = space * lpeg.P("=") * space
local value = lpeg.C((1 - lpeg.P("\n"))^0)
local line = name * eq * value

local key, val = lpeg.match(line, "DATABASE_URL=postgresql://localhost/db")
-- Returns: "DATABASE_URL", "postgresql://localhost/db"
```

#### Example 5: Request Handler with Pattern Matching

```lua
-- api_handler.lua using lpeg for input validation
function handle(request, response, context)
    local path = request:path()
    
    -- Parse user ID from path like /api/users/123
    local digit = lpeg.R("09")
    local user_id_pattern = lpeg.P("/api/users/") * lpeg.C(digit^1)
    local user_id = lpeg.match(user_id_pattern, path)
    
    if user_id then
        return {
            status = "success",
            user_id = tonumber(user_id),
            message = "User ID extracted: " .. user_id
        }
    else
        return {
            status = "error",
            message = "Invalid URL format"
        }
    end
end

return { handle = handle }
```

### Advanced Features

#### Grammar Support

LPeg can define complete grammars using the `lpeg.V()` (variable) function:

```lua
-- Simple arithmetic expression grammar
local V = lpeg.V
local grammar = lpeg.P({
    "expr",
    expr = V("term") * ((lpeg.S("+-") * V("term"))^0),
    term = V("factor") * ((lpeg.S("*/") * V("factor"))^0),
    factor = lpeg.R("09")^1 + lpeg.P("(") * V("expr") * lpeg.P(")"),
})

local result = lpeg.match(grammar, "1+2*3")
```

#### More Capture Types

- `lpeg.Ct(pattern)`: Table capture - collects all captures in a table
- `lpeg.Cc(values)`: Constant capture - returns fixed values
- `lpeg.Cg(pattern, name)`: Group capture - named captures
- `lpeg.Cb(name)`: Back capture - references named captures
- `lpeg.Cf(pattern, func)`: Fold capture - accumulates results using a function

### Best Practices

1. **Reuse Patterns**: Define common patterns once and reuse them
```lua
local common = {
    space = lpeg.S(" \t\n")^0,
    digit = lpeg.R("09"),
    letter = lpeg.R("az", "AZ"),
    identifier = lpeg.C((lpeg.R("az", "AZ") * lpeg.R("az", "AZ", "09", "__")^0))
}
```

2. **Use Meaningful Names**: Make patterns self-documenting
```lua
local email_username = (letter + digit + lpeg.S("_-."))^1
local email_domain = (letter + digit + lpeg.S("-"))^1
```

3. **Test Incrementally**: Build complex patterns from tested simple ones
```lua
-- Test each component separately
local sign_test = lpeg.match(sign, "+")  -- Verify sign works
local digits_test = lpeg.match(digits, "123")  -- Verify digits work
-- Then combine them
```

4. **Handle Edge Cases**: Consider what happens with empty strings, special characters, etc.

### Performance Tips

- LPeg patterns are compiled once and can be reused efficiently
- Use captures only when needed (they have overhead)
- For simple matching, `lpeg.P()` is faster than `lpeg.C()`
- Cache compiled patterns at module level for best performance

### References

- [LPeg Official Documentation](http://www.inf.puc-rio.br/~roberto/lpeg/)
- [LPeg Tutorial](http://www.inf.puc-rio.br/~roberto/lpeg/lpeg.html)
- See `examples/lua/lpeg_test.lua` for more working examples

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

The built-in json and lpeg modules are:
- Safe (work within sandbox)
- Fast (implemented in C/Zig, no FFI overhead)
- Compatible with both Lua 5.4 and LuaJIT

Use lpeg for complex pattern matching instead of external regex libraries.

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

### "json not found" or "lpeg not found" error

The `json` and `lpeg` globals should be available automatically. Check that zhttpd is initialized correctly.

### "Lua handler execution failed" error

This can occur due to:
- Instruction limit exceeded (increase `lua_max_instructions`)
- Runtime error in Lua script (check script logic)
- Invalid JSON in request body
- Pattern matching error in lpeg (check pattern syntax)

### LuaJIT build fails

LuaJIT has specific platform requirements. If the build fails:
1. Try building with standard Lua 5.4 (default)
2. Ensure you have required system libraries (libunwind)
3. Check platform compatibility

## Version Compatibility

| Feature | Lua 5.4 | LuaJIT |
|---------|---------|--------|
| Built-in json | ✅ | ✅ |
| Built-in lpeg | ✅ | ✅ |
| Sandbox | ✅ | ✅ |
| Package library (when sandbox disabled) | ✅ | ✅ |
| FFI | ❌ | ✅ |
| Instruction limit hook | ✅ | ✅ |

---

For more information, see:
- [zhttpd README](../README.md)
- [Lua Documentation](https://www.lua.org/manual/5.4/)
- [LuaJIT Documentation](https://luajit.org/luajit.html)

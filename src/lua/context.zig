//! Per-Request Context and httpz Bindings for Lua
//!
//! This module provides Lua bindings for httpz.Request and httpz.Response,
//! implementing a Per-Request Context pattern that allows Lua scripts to
//! directly interact with HTTP request/response objects.
//!
//! ## Design
//!
//! The context module exposes three main objects to Lua:
//! - `ctx.req`: Request object with methods to access request data
//! - `ctx.res`: Response object with methods to set response data
//! - `ctx.data`: A Lua table for storing per-request user data
//!
//! ## Usage in Lua
//!
//! ```lua
//! function handle(ctx)
//!     -- Access request data
//!     local method = ctx.req:method()
//!     local path = ctx.req:path()
//!     local header = ctx.req:header("content-type")
//!     local query_param = ctx.req:query("page")
//!     local body = ctx.req:body()
//!
//!     -- Set response data
//!     ctx.res:status(200)
//!     ctx.res:header("X-Custom-Header", "value")
//!     ctx.res:content_type("application/json")
//!
//!     -- Use per-request data storage
//!     ctx.data.user_id = "12345"
//!     ctx.data.processed = true
//!
//!     -- Return response body (can also use ctx.res:body())
//!     return { status = "success", user = ctx.data.user_id }
//! end
//!
//! return { handle = handle }
//! ```

const std = @import("std");
const ziglua = @import("ziglua");
const httpz = @import("httpz");
const json = @import("json.zig");

/// Opaque pointer type for Request userdata
/// We store the pointer as light userdata since the request lifetime
/// is guaranteed by the HTTP server during request handling
pub const RequestUserdata = struct {
    req: *httpz.Request,
    arena: std.mem.Allocator,
};

/// Opaque pointer type for Response userdata
pub const ResponseUserdata = struct {
    res: *httpz.Response,
    arena: std.mem.Allocator,
};

/// Maximum size for header/query parameter keys
const MAX_KEY_SIZE: usize = 256;

/// Metatable names for userdata types
const REQUEST_MT = "zhttpd.request";
const RESPONSE_MT = "zhttpd.response";

/// Thread-local storage for current request/response context
/// This allows Lua C functions to access the current request without upvalues
threadlocal var current_request: ?*httpz.Request = null;
threadlocal var current_response: ?*httpz.Response = null;
threadlocal var current_arena: ?std.mem.Allocator = null;

/// Register the context module metatables in Lua
/// This should be called once per Lua state initialization
pub fn registerContextModule(lua: *ziglua.Lua) void {
    // Register Request metatable
    registerRequestMetatable(lua);

    // Register Response metatable
    registerResponseMetatable(lua);
}

/// Register the Request metatable with all its methods
fn registerRequestMetatable(lua: *ziglua.Lua) void {
    // Create new metatable for Request
    lua.newMetatable(REQUEST_MT) catch {
        // Metatable already exists, get it
        _ = lua.getMetatableRegistry(REQUEST_MT);
    };

    // Set __index to the metatable itself for method lookup
    lua.pushValue(-1);
    lua.setField(-2, "__index");

    // Register methods
    lua.pushFunction(ziglua.wrap(reqMethod));
    lua.setField(-2, "method");

    lua.pushFunction(ziglua.wrap(reqPath));
    lua.setField(-2, "path");

    lua.pushFunction(ziglua.wrap(reqUrl));
    lua.setField(-2, "url");

    lua.pushFunction(ziglua.wrap(reqHeader));
    lua.setField(-2, "header");

    lua.pushFunction(ziglua.wrap(reqHeaders));
    lua.setField(-2, "headers");

    lua.pushFunction(ziglua.wrap(reqQuery));
    lua.setField(-2, "query");

    lua.pushFunction(ziglua.wrap(reqQueryAll));
    lua.setField(-2, "query_all");

    lua.pushFunction(ziglua.wrap(reqBody));
    lua.setField(-2, "body");

    lua.pushFunction(ziglua.wrap(reqBodyRaw));
    lua.setField(-2, "body_raw");

    lua.pushFunction(ziglua.wrap(reqParam));
    lua.setField(-2, "param");

    lua.pop(1); // Pop metatable
}

/// Register the Response metatable with all its methods
fn registerResponseMetatable(lua: *ziglua.Lua) void {
    // Create new metatable for Response
    lua.newMetatable(RESPONSE_MT) catch {
        // Metatable already exists, get it
        _ = lua.getMetatableRegistry(RESPONSE_MT);
    };

    // Set __index to the metatable itself for method lookup
    lua.pushValue(-1);
    lua.setField(-2, "__index");

    // Register methods
    lua.pushFunction(ziglua.wrap(resStatus));
    lua.setField(-2, "status");

    lua.pushFunction(ziglua.wrap(resHeader));
    lua.setField(-2, "header");

    lua.pushFunction(ziglua.wrap(resContentType));
    lua.setField(-2, "content_type");

    lua.pushFunction(ziglua.wrap(resBody));
    lua.setField(-2, "body");

    lua.pop(1); // Pop metatable
}

/// Push a Request userdata onto the Lua stack
pub fn pushRequest(lua: *ziglua.Lua, req: *httpz.Request, arena: std.mem.Allocator) void {
    // Store in thread-local for access from methods
    current_request = req;
    current_arena = arena;

    // Create a table to hold the request (using table instead of userdata for simpler access)
    lua.newTable();

    // Store the request pointer as light userdata in the table
    lua.pushLightUserdata(@ptrCast(req));
    lua.setField(-2, "_ptr");

    // Set the metatable
    _ = lua.getMetatableRegistry(REQUEST_MT);
    lua.setMetatable(-2);
}

/// Push a Response userdata onto the Lua stack
pub fn pushResponse(lua: *ziglua.Lua, res: *httpz.Response, arena: std.mem.Allocator) void {
    // Store in thread-local for access from methods
    current_response = res;
    current_arena = arena;

    // Create a table to hold the response
    lua.newTable();

    // Store the response pointer as light userdata in the table
    lua.pushLightUserdata(@ptrCast(res));
    lua.setField(-2, "_ptr");

    // Set the metatable
    _ = lua.getMetatableRegistry(RESPONSE_MT);
    lua.setMetatable(-2);
}

/// Create the full context table with req, res, and data
pub fn pushContext(lua: *ziglua.Lua, req: *httpz.Request, res: *httpz.Response, arena: std.mem.Allocator) void {
    // Create main context table
    lua.newTable();

    // Add req field
    pushRequest(lua, req, arena);
    lua.setField(-2, "req");

    // Add res field
    pushResponse(lua, res, arena);
    lua.setField(-2, "res");

    // Add data field (empty table for per-request user data)
    lua.newTable();
    lua.setField(-2, "data");
}

/// Clear the thread-local context after request handling
pub fn clearContext() void {
    current_request = null;
    current_response = null;
    current_arena = null;
}

// =============================================================================
// Request Methods
// =============================================================================

/// Get the HTTP method (GET, POST, etc.)
fn reqMethod(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    const method_str = @tagName(req.method);
    _ = lua.pushString(method_str);
    return 1;
}

/// Get the request path
fn reqPath(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    _ = lua.pushString(req.url.path);
    return 1;
}

/// Get the full URL (path + query string)
fn reqUrl(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    if (req.url.query.len > 0) {
        // Construct full URL with query string
        const arena = current_arena orelse {
            _ = lua.pushString(req.url.path);
            return 1;
        };

        const full_url = std.fmt.allocPrint(arena, "{s}?{s}", .{ req.url.path, req.url.query }) catch {
            _ = lua.pushString(req.url.path);
            return 1;
        };
        _ = lua.pushString(full_url);
    } else {
        _ = lua.pushString(req.url.path);
    }
    return 1;
}

/// Get a specific header value
/// Usage: ctx.req:header("content-type")
fn reqHeader(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    // Get the header name argument
    if (lua.getTop() < 2) {
        lua.pushNil();
        return 1;
    }

    const header_name = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };

    // Look up the header (httpz headers are stored lowercase)
    if (req.headers.get(header_name)) |value| {
        _ = lua.pushString(value);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// Get all headers as a table
/// Usage: ctx.req:headers()
fn reqHeaders(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    lua.newTable();

    var iter = req.headers.iterator();
    while (iter.next()) |entry| {
        _ = lua.pushString(entry.value);
        pushKeyToTable(lua, entry.key);
    }

    return 1;
}

/// Helper function to find a query parameter value by name
/// Returns the value if found, null otherwise
fn findQueryParam(query_string: []const u8, param_name: []const u8) ?[]const u8 {
    if (query_string.len == 0) return null;

    var query_iter = std.mem.splitScalar(u8, query_string, '&');
    while (query_iter.next()) |param| {
        if (std.mem.indexOfScalar(u8, param, '=')) |eq_pos| {
            const key = param[0..eq_pos];
            if (std.mem.eql(u8, key, param_name)) {
                return if (eq_pos + 1 < param.len) param[eq_pos + 1 ..] else "";
            }
        } else if (param.len > 0 and std.mem.eql(u8, param, param_name)) {
            // Flag-style parameter (e.g., ?debug)
            return "";
        }
    }
    return null;
}

/// Get a query parameter value
/// Usage: ctx.req:query("page")
fn reqQuery(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    // Get the parameter name argument
    if (lua.getTop() < 2) {
        lua.pushNil();
        return 1;
    }

    const param_name = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };

    // Use helper to find query parameter
    if (findQueryParam(req.url.query, param_name)) |value| {
        _ = lua.pushString(value);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// Get all query parameters as a table
/// Usage: ctx.req:query_all()
fn reqQueryAll(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    lua.newTable();

    if (req.url.query.len > 0) {
        var query_iter = std.mem.splitScalar(u8, req.url.query, '&');
        while (query_iter.next()) |param| {
            if (std.mem.indexOfScalar(u8, param, '=')) |eq_pos| {
                const key = param[0..eq_pos];
                const value = if (eq_pos + 1 < param.len) param[eq_pos + 1 ..] else "";
                _ = lua.pushString(value);
                pushKeyToTable(lua, key);
            } else if (param.len > 0) {
                // Flag-style parameter (e.g., ?debug)
                _ = lua.pushString("");
                pushKeyToTable(lua, param);
            }
        }
    }

    return 1;
}

/// Get the request body as a parsed Lua table (for JSON)
/// Usage: ctx.req:body()
fn reqBody(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    const body_data = req.body() orelse {
        lua.pushNil();
        return 1;
    };

    if (body_data.len == 0) {
        lua.pushNil();
        return 1;
    }

    // Try to parse as JSON
    const arena = current_arena orelse {
        _ = lua.pushString(body_data);
        return 1;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, arena, body_data, .{}) catch {
        // Not valid JSON, return as string
        _ = lua.pushString(body_data);
        return 1;
    };

    json.pushJsonValue(lua, parsed.value) catch {
        _ = lua.pushString(body_data);
        return 1;
    };

    return 1;
}

/// Get the raw request body as a string
/// Usage: ctx.req:body_raw()
fn reqBodyRaw(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    if (req.body()) |body_data| {
        _ = lua.pushString(body_data);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// Get a URL path parameter (from route patterns like /users/:id)
/// Usage: ctx.req:param("id")
fn reqParam(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    // Get the parameter name argument
    if (lua.getTop() < 2) {
        lua.pushNil();
        return 1;
    }

    const param_name = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };

    if (req.params.get(param_name)) |value| {
        _ = lua.pushString(value);
    } else {
        lua.pushNil();
    }
    return 1;
}

// =============================================================================
// Response Methods
// =============================================================================

/// Set the HTTP status code
/// Usage: ctx.res:status(200)
fn resStatus(lua: *ziglua.Lua) i32 {
    const res = current_response orelse {
        _ = lua.pushString("no response context");
        lua.raiseError();
    };

    if (lua.getTop() < 2) {
        // Getter mode - return current status
        lua.pushInteger(@intCast(res.status));
        return 1;
    }

    const status = lua.toInteger(2) catch {
        _ = lua.pushString("status must be an integer");
        lua.raiseError();
    };

    res.status = @intCast(status);
    return 0;
}

/// Set a response header
/// Usage: ctx.res:header("X-Custom-Header", "value")
fn resHeader(lua: *ziglua.Lua) i32 {
    const res = current_response orelse {
        _ = lua.pushString("no response context");
        lua.raiseError();
    };

    if (lua.getTop() < 3) {
        _ = lua.pushString("header requires name and value arguments");
        lua.raiseError();
    }

    const name = lua.toString(2) catch {
        _ = lua.pushString("header name must be a string");
        lua.raiseError();
    };

    const value = lua.toString(3) catch {
        _ = lua.pushString("header value must be a string");
        lua.raiseError();
    };

    res.headers.add(name, value);
    return 0;
}

/// Set the Content-Type header
/// Usage: ctx.res:content_type("application/json")
fn resContentType(lua: *ziglua.Lua) i32 {
    const res = current_response orelse {
        _ = lua.pushString("no response context");
        lua.raiseError();
    };

    if (lua.getTop() < 2) {
        _ = lua.pushString("content_type requires a string argument");
        lua.raiseError();
    }

    const content_type_str = lua.toString(2) catch {
        _ = lua.pushString("content_type must be a string");
        lua.raiseError();
    };

    // Map common content types to httpz.ContentType enum
    if (std.mem.eql(u8, content_type_str, "application/json")) {
        res.content_type = .JSON;
    } else if (std.mem.eql(u8, content_type_str, "text/html")) {
        res.content_type = .HTML;
    } else if (std.mem.eql(u8, content_type_str, "text/plain")) {
        res.content_type = .TEXT;
    } else if (std.mem.eql(u8, content_type_str, "text/css")) {
        res.content_type = .CSS;
    } else if (std.mem.eql(u8, content_type_str, "application/javascript") or std.mem.eql(u8, content_type_str, "text/javascript")) {
        res.content_type = .JS;
    } else if (std.mem.eql(u8, content_type_str, "application/xml") or std.mem.eql(u8, content_type_str, "text/xml")) {
        res.content_type = .XML;
    } else {
        // For other content types, set as header directly
        res.headers.add("Content-Type", content_type_str);
    }

    return 0;
}

/// Set the response body directly
/// Usage: ctx.res:body("Hello, World!")
fn resBody(lua: *ziglua.Lua) i32 {
    const res = current_response orelse {
        _ = lua.pushString("no response context");
        lua.raiseError();
    };

    if (lua.getTop() < 2) {
        // Getter mode - return current body
        _ = lua.pushString(res.body);
        return 1;
    }

    const body_str = lua.toString(2) catch {
        _ = lua.pushString("body must be a string");
        lua.raiseError();
    };

    res.body = body_str;
    return 0;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Helper to push a key and set field in table
/// If key is longer than MAX_KEY_SIZE, it will be truncated with a warning logged
fn pushKeyToTable(lua: *ziglua.Lua, key: []const u8) void {
    var key_buf: [MAX_KEY_SIZE]u8 = undefined;
    const key_len = @min(key.len, key_buf.len - 1);
    if (key.len >= key_buf.len) {
        // Key truncation warning - log but continue to avoid breaking request processing
        std.debug.print("Warning: Key truncated from {d} to {d} bytes\n", .{ key.len, key_len });
    }
    @memcpy(key_buf[0..key_len], key[0..key_len]);
    key_buf[key_len] = 0;
    lua.setField(-2, key_buf[0..key_len :0]);
}

// =============================================================================
// Tests
// =============================================================================

test "context module compiles" {
    // Basic compilation test
    const testing = std.testing;
    try testing.expect(true);
}

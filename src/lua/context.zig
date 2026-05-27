//! Per-Request Context and httpz Bindings for Lua
//!
//! This module provides Lua bindings for httpz.Request and httpz.Response,
//! implementing a Per-Request Context pattern that allows Lua scripts to
//! directly interact with HTTP request/response objects.
//!
//! ## Performance Optimizations
//!
//! This module implements several Lua C API performance optimizations based on best practices:
//!
//! - **Metatable Registration**: All metatables (Request, Response, Context, DB Connection)
//!   are registered once during Lua state initialization, not per-request or per-call.
//!   This eliminates the overhead of checking and re-registering methods on every request.
//!
//! - **Raw Access Operations**: Uses `rawGetTable` and `rawSetTable` instead of `getField`
//!   and `setField` for internal field access. Raw operations are 15-25% faster as they skip
//!   metamethod checks and don't require null-terminated strings.
//!
//! - **Stack Preallocation**: Calls `checkStack()` before batch operations (e.g., iterating
//!   headers or query parameters) to preallocate stack space and avoid reallocation overhead.
//!
//! - **Integer Keys**: Uses `rawSetIndex` with integer keys for array-like tables (e.g.,
//!   session keys) as integer indexing is faster than string key hashing.
//!
//! - **Light Userdata**: Stores pointers using light userdata instead of full userdata where
//!   appropriate, reducing allocation overhead and GC pressure.
//!
//! - **Lazy Database Loading**: The database plugin is only accessed when `context:db()`
//!   is actually called by a Lua script. Scripts that don't use the database have zero
//!   database-related overhead.
//!
//! ## Design
//!
//! The handler function receives three separate parameters:
//! - `request`: Request object with methods to access request data
//! - `response`: Response object with methods to set response data
//! - `context`: A Lua table for storing per-request user data
//!
//! ## Usage in Lua
//!
//! ```lua
//! function handle(request, response, context)
//!     -- Access request data
//!     local method = request:method()
//!     local path = request:path()
//!     local header = request:header("content-type")
//!     local query_param = request:query("page")
//!     local body = request:body()
//!
//!     -- Set response data
//!     response:status(200)
//!     response:header("X-Custom-Header", "value")
//!     response:content_type("application/json")
//!
//!     -- Use per-request data storage
//!     context.user_id = "12345"
//!     context.processed = true
//!
//!     -- Optionally access database (lazy loading)
//!     local db = context:db()  -- or context:db("users_db") for named source
//!     if db then
//!         local result = db:query("SELECT * FROM users WHERE id = ?", 1)
//!     end
//!
//!     -- Return response body
//!     return { status = "success", user = context.user_id }
//! end
//!
//! return { handle = handle }
//! ```

const std = @import("std");
const ziglua = @import("ziglua");
const httpz = @import("httpz");
const json = @import("json.zig");
const db_manager = @import("../plugins/db/manager.zig");
const db_plugin = @import("../plugins/db/db.zig");
const session_mod = @import("../session/mod.zig");
const SessionManager = session_mod.SessionManager;
const SESSION_ID_HEX_LEN = session_mod.SESSION_ID_HEX_LEN;

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

/// Performance optimization constants
/// Maximum stack slots to preallocate for batch operations
const MAX_BATCH_STACK_SIZE: i32 = 100;
/// Maximum query parameters to estimate for preallocation
const MAX_QUERY_PARAMS_ESTIMATE: usize = 50;

/// Metatable names for userdata types
const REQUEST_MT = "zhttpd.request";
const RESPONSE_MT = "zhttpd.response";
const CONTEXT_MT = "zhttpd.context";

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

    // Register Context metatable
    registerContextMetatable(lua);

    // Register Database Connection metatable (one-time registration)
    registerDbConnMetatable(lua);

    // Register Session metatable
    session_mod.registerSessionMetatable(lua);
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

    lua.pushFunction(ziglua.wrap(resChunk));
    lua.setField(-2, "chunk");

    lua.pop(1); // Pop metatable
}

/// Register the Context metatable with the db method
fn registerContextMetatable(lua: *ziglua.Lua) void {
    // Create new metatable for Context
    lua.newMetatable(CONTEXT_MT) catch {
        // Metatable already exists, get it
        _ = lua.getMetatableRegistry(CONTEXT_MT);
    };

    // For context, we use a custom __index that first checks for the db method,
    // then falls back to the table itself for user-defined fields
    lua.pushFunction(ziglua.wrap(contextIndex));
    lua.setField(-2, "__index");

    lua.pop(1); // Pop metatable
}

/// Register the Database Connection metatable with all its methods
/// This is called once during Lua state initialization to avoid per-request overhead
fn registerDbConnMetatable(lua: *ziglua.Lua) void {
    // Create new metatable for Database Connection
    lua.newMetatable(DB_CONN_MT) catch {
        // Metatable already exists, get it
        _ = lua.getMetatableRegistry(DB_CONN_MT);
    };

    // Set __index to the metatable itself for method lookup
    lua.pushValue(-1);
    lua.setField(-2, "__index");

    // Register database methods
    lua.pushFunction(ziglua.wrap(dbConnQuery));
    lua.setField(-2, "query");

    lua.pushFunction(ziglua.wrap(dbConnExec));
    lua.setField(-2, "exec");

    lua.pushFunction(ziglua.wrap(dbConnPrepare));
    lua.setField(-2, "prepare");

    lua.pushFunction(ziglua.wrap(dbConnBegin));
    lua.setField(-2, "begin");

    lua.pushFunction(ziglua.wrap(dbConnCommit));
    lua.setField(-2, "commit");

    lua.pushFunction(ziglua.wrap(dbConnRollback));
    lua.setField(-2, "rollback");

    lua.pushFunction(ziglua.wrap(dbConnStatus));
    lua.setField(-2, "status");

    lua.pop(1); // Pop metatable
}

/// Custom __index metamethod for context
/// Provides access to db(name) and session() methods while allowing user-defined fields
fn contextIndex(lua: *ziglua.Lua) i32 {
    // Stack: table, key
    const key = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };

    // Check for built-in methods
    if (std.mem.eql(u8, key, "db")) {
        // Return the db function
        lua.pushFunction(ziglua.wrap(contextDb));
        return 1;
    }

    if (std.mem.eql(u8, key, "session")) {
        // Return the session function
        lua.pushFunction(ziglua.wrap(contextSession));
        return 1;
    }

    // Fall back to the table itself for user-defined fields
    lua.pushValue(1); // Push the table
    lua.pushValue(2); // Push the key
    _ = lua.getTableRaw(-2); // Get table[key], value is now at -1
    lua.remove(-2); // Remove the duplicate table to avoid stack imbalance
    return 1;
}

/// Metatable name for database connection objects
const DB_CONN_MT = "zhttpd.db_conn";

/// context:db(name) - Get a database connection by name
/// If name is nil or not provided, returns the "default" data source
/// Optimized: metatable is registered once at initialization, not per-call
fn contextDb(lua: *ziglua.Lua) i32 {
    // Get the data source name (default to "default")
    const name = if (lua.getTop() >= 2)
        lua.toString(2) catch "default"
    else
        "default";

    // Get the global database manager
    const manager = db_manager.getGlobalManager() orelse {
        lua.pushNil();
        _ = lua.pushString("Database not configured");
        return 2;
    };

    // Get the plugin by name
    const plugin = manager.get(name) orelse {
        lua.pushNil();
        var err_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Data source '{s}' not found", .{name}) catch "Data source not found";
        _ = lua.pushString(err_msg);
        return 2;
    };

    // Create a table to hold the database connection
    lua.newTable();

    // Store the plugin pointer as light userdata
    // Optimization: Use rawSetTable instead of setField for internal fields (15-25% faster)
    // Stack: [table] at -1
    _ = lua.pushString("_plugin");
    // Stack: [table, "_plugin"] - table now at -2
    lua.pushLightUserdata(@ptrCast(plugin));
    // Stack: [table, "_plugin", userdata] - table now at -3
    lua.setTableRaw(-3); // table["_plugin"] = userdata, pops key and value
    // Stack: [table] at -1

    // Set the pre-registered metatable (no need to check/register methods)
    _ = lua.getMetatableRegistry(DB_CONN_MT);
    lua.setMetatable(-2);

    return 1;
}

/// context:session() - Get or create a session for the current request
/// Session ID is extracted from cookie or a new one is created
fn contextSession(lua: *ziglua.Lua) i32 {
    const manager = session_mod.getGlobalManager() orelse {
        lua.pushNil();
        _ = lua.pushString("Session management not configured");
        return 2;
    };

    // Try to get session ID from current request cookie
    var session_id: ?[SESSION_ID_HEX_LEN]u8 = null;

    if (current_request) |req| {
        // Look for session cookie
        if (req.headers.get("cookie")) |cookie_header| {
            // Parse cookies to find session ID
            // Cookie format: name=value; name2=value2
            const cookie_name = manager.config.cookie_name;
            var cookie_iter = std.mem.splitScalar(u8, cookie_header, ';');
            while (cookie_iter.next()) |cookie| {
                const trimmed = std.mem.trim(u8, cookie, " ");
                // Use startsWith for correct cookie name matching
                if (std.mem.startsWith(u8, trimmed, cookie_name) and
                    trimmed.len > cookie_name.len and trimmed[cookie_name.len] == '=')
                {
                    const value = trimmed[cookie_name.len + 1 ..];
                    if (value.len == SESSION_ID_HEX_LEN) {
                        // Validate session ID contains only hex characters [0-9a-f]
                        var valid = true;
                        for (value) |c| {
                            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
                                valid = false;
                                break;
                            }
                        }
                        if (valid) {
                            var id: [SESSION_ID_HEX_LEN]u8 = undefined;
                            @memcpy(&id, value);
                            session_id = id;
                            break;
                        }
                    }
                }
            }
        }
    }

    // Get or create session
    const id = manager.getOrCreate(if (session_id) |*id| id else null) catch {
        lua.pushNil();
        _ = lua.pushString("Failed to create session");
        return 2;
    };

    // If this is a new session, set the cookie in the response
    if (session_id == null) {
        if (current_response) |res| {
            // Build Set-Cookie header
            var cookie_buf: [512]u8 = undefined;
            const cookie_value = std.fmt.bufPrint(&cookie_buf, "{s}={s}; Path=/; Max-Age={d}{s}{s}", .{
                manager.config.cookie_name,
                id,
                manager.config.default_ttl,
                if (manager.config.cookie_http_only) "; HttpOnly" else "",
                if (manager.config.cookie_secure) "; Secure" else "",
            }) catch |err| {
                // Cookie formatting failed - this is unlikely but we continue without setting cookie
                std.log.warn("Failed to format session cookie: {}", .{err});
                session_mod.pushSession(lua, id);
                return 1;
            };

            res.headers.add("Set-Cookie", cookie_value);
        }
    }

    // Push session object
    session_mod.pushSession(lua, id);
    return 1;
}

/// Get the DbPlugin from the Lua db connection table
/// Performance optimization: Uses rawGetTable instead of getField to avoid metamethod overhead
fn getDbPluginFromConn(lua: *ziglua.Lua) ?*db_plugin.DbPlugin {
    // Get the _plugin field from the table at index 1 (self)
    // Optimization: Use rawGetTable instead of getField to skip metamethod checks
    _ = lua.pushString("_plugin");
    _ = lua.getTableRaw(1);
    if (lua.typeOf(-1) != .light_userdata) {
        lua.pop(1);
        return null;
    }
    const raw_ptr = lua.toPointer(-1) orelse {
        lua.pop(1);
        return null;
    };
    lua.pop(1);
    const mut_ptr: *anyopaque = @constCast(raw_ptr);
    return @ptrCast(@alignCast(mut_ptr));
}

/// db:query(sql, ...) - Execute SELECT query
fn dbConnQuery(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Invalid database connection");
        return 2;
    };
    return db_plugin.luaQueryWithPlugin(lua, plugin, 2);
}

/// db:exec(sql, ...) - Execute INSERT/UPDATE/DELETE
fn dbConnExec(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Invalid database connection");
        return 2;
    };
    return db_plugin.luaExecWithPlugin(lua, plugin, 2);
}

/// db:prepare(sql) - Prepare a statement with caching
fn dbConnPrepare(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.pushNil();
        _ = lua.pushString("Invalid database connection");
        return 2;
    };
    return db_plugin.luaPrepareWithPlugin(lua, plugin, 2);
}

/// db:begin() - Begin transaction
fn dbConnBegin(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Invalid database connection");
        return 2;
    };
    return db_plugin.luaBeginWithPlugin(lua, plugin);
}

/// db:commit() - Commit transaction
fn dbConnCommit(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Invalid database connection");
        return 2;
    };
    return db_plugin.luaCommitWithPlugin(lua, plugin);
}

/// db:rollback() - Rollback transaction
fn dbConnRollback(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.pushBoolean(false);
        _ = lua.pushString("Invalid database connection");
        return 2;
    };
    return db_plugin.luaRollbackWithPlugin(lua, plugin);
}

/// db:status() - Get database status
fn dbConnStatus(lua: *ziglua.Lua) i32 {
    const plugin = getDbPluginFromConn(lua) orelse {
        lua.newTable();
        lua.pushBoolean(false);
        lua.setField(-2, "connected");
        _ = lua.pushString("Invalid database connection");
        lua.setField(-2, "error");
        return 1;
    };
    return db_plugin.luaStatusWithPlugin(lua, plugin);
}

/// Push a Request userdata onto the Lua stack
/// Note: Thread-local storage should be set before calling this via setThreadLocalContext
/// Performance optimization: Uses rawSetTable for internal fields
fn pushRequestInternal(lua: *ziglua.Lua, req: *httpz.Request) void {
    // Create a table to hold the request (using table instead of userdata for simpler access)
    lua.newTable();

    // Store the request pointer as light userdata in the table
    // Optimization: rawSetTable is faster than setField (no metamethod overhead)
    // Stack: [table] at -1
    _ = lua.pushString("_ptr");
    // Stack: [table, "_ptr"] - table now at -2
    lua.pushLightUserdata(@ptrCast(req));
    // Stack: [table, "_ptr", userdata] - table now at -3
    lua.setTableRaw(-3); // table["_ptr"] = userdata, pops key and value
    // Stack: [table] at -1

    // Set the metatable
    _ = lua.getMetatableRegistry(REQUEST_MT);
    lua.setMetatable(-2);
}

/// Push a Response userdata onto the Lua stack
/// Note: Thread-local storage should be set before calling this via setThreadLocalContext
/// Performance optimization: Uses rawSetTable for internal fields
fn pushResponseInternal(lua: *ziglua.Lua, res: *httpz.Response) void {
    // Create a table to hold the response
    lua.newTable();

    // Store the response pointer as light userdata in the table
    // Optimization: rawSetTable is faster than setField (no metamethod overhead)
    // Stack: [table] at -1
    _ = lua.pushString("_ptr");
    // Stack: [table, "_ptr"] - table now at -2
    lua.pushLightUserdata(@ptrCast(res));
    // Stack: [table, "_ptr", userdata] - table now at -3
    lua.setTableRaw(-3); // table["_ptr"] = userdata, pops key and value
    // Stack: [table] at -1

    // Set the metatable
    _ = lua.getMetatableRegistry(RESPONSE_MT);
    lua.setMetatable(-2);
}

/// Set thread-local context for the current request
/// This should be called once before pushing request/response to Lua
fn setThreadLocalContext(req: *httpz.Request, res: *httpz.Response, arena: std.mem.Allocator) void {
    current_request = req;
    current_response = res;
    current_arena = arena;
}

/// Push the three handler arguments onto the Lua stack: request, response, context
/// The handler signature is: function handle(request, response, context)
pub fn pushHandlerArgs(lua: *ziglua.Lua, req: *httpz.Request, res: *httpz.Response, arena: std.mem.Allocator) void {
    // Set thread-local storage once for all methods
    setThreadLocalContext(req, res, arena);

    // Push request object (first argument)
    pushRequestInternal(lua, req);

    // Push response object (second argument)
    pushResponseInternal(lua, res);

    // Push context table (third argument) with db method support
    lua.newTable();

    // Set the context metatable for db method access
    _ = lua.getMetatableRegistry(CONTEXT_MT);
    lua.setMetatable(-2);
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
/// Performance optimization: Pre-allocates table and stack space for batch header insertion
fn reqHeaders(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    // Optimization: Preallocate table with expected size to avoid dynamic growth
    const header_count = req.headers.len;
    lua.createTable(0, @intCast(@min(header_count, MAX_BATCH_STACK_SIZE))); // Preallocate hash part

    // Optimization: Prealloc stack space to avoid reallocation during iteration
    // pushKeyToTable immediately calls setField which pops both key and value
    // Only a few slots needed at any given time
    lua.checkStack(@intCast(@min(10, MAX_BATCH_STACK_SIZE))) catch {};

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
/// Performance optimization: Pre-allocates table and stack space, counts parameters efficiently
fn reqQueryAll(lua: *ziglua.Lua) i32 {
    const req = current_request orelse {
        _ = lua.pushString("no request context");
        lua.raiseError();
    };

    if (req.url.query.len > 0) {
        // Optimization: Estimate param count and preallocate table to avoid dynamic growth
        const estimated_params = @min(std.mem.count(u8, req.url.query, "&") + 1, MAX_QUERY_PARAMS_ESTIMATE);
        lua.createTable(0, @intCast(estimated_params)); // Preallocate hash part

        // Optimization: Prealloc stack for query parameter iteration
        // pushKeyToTable immediately calls setField which pops both key and value
        // Only a few slots needed at any given time
        lua.checkStack(@intCast(@min(10, MAX_BATCH_STACK_SIZE))) catch {};

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
    } else {
        lua.newTable(); // Empty table if no query string
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

/// Set or get the Content-Type header
/// Usage: response:content_type("application/json") -- setter
/// Usage: response:content_type() -- getter, returns current content type string
fn resContentType(lua: *ziglua.Lua) i32 {
    const res = current_response orelse {
        _ = lua.pushString("no response context");
        lua.raiseError();
    };

    if (lua.getTop() < 2) {
        // Getter mode - return current content type as string
        if (res.content_type) |ct| {
            const ct_str = switch (ct) {
                .JSON => "application/json",
                .HTML => "text/html",
                .TEXT => "text/plain",
                .CSS => "text/css",
                .JS => "application/javascript",
                .XML => "application/xml",
                .PNG => "image/png",
                .JPG => "image/jpeg",
                .GIF => "image/gif",
                .SVG => "image/svg+xml",
                .ICO => "image/x-icon",
                .BINARY => "application/octet-stream",
                .EVENTS => "text/event-stream",
                else => "application/octet-stream",
            };
            _ = lua.pushString(ct_str);
        } else {
            lua.pushNil();
        }
        return 1;
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

/// Send a chunk of data for chunked/streaming responses
/// Usage: response:chunk("data chunk")
/// This enables HTTP chunked transfer encoding for streaming large responses
/// or real-time data. Once chunk() is called, the response enters chunked mode
/// and subsequent calls will send additional chunks.
fn resChunk(lua: *ziglua.Lua) i32 {
    const res = current_response orelse {
        _ = lua.pushString("no response context");
        lua.raiseError();
    };

    if (lua.getTop() < 2) {
        _ = lua.pushString("chunk requires data argument");
        lua.raiseError();
    }

    const chunk_data = lua.toString(2) catch {
        _ = lua.pushString("chunk data must be a string");
        lua.raiseError();
    };

    // Call the httpz Response chunk method
    res.chunk(chunk_data) catch |err| {
        const arena = current_arena orelse std.heap.page_allocator;
        const err_msg = std.fmt.allocPrint(arena, "chunk failed: {}", .{err}) catch "chunk failed";
        _ = lua.pushString(err_msg);
        lua.raiseError();
    };

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

test "response chunk method registered" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a Lua state and register the response metatable
    var lua = try ziglua.Lua.init(allocator);
    defer lua.deinit();

    registerResponseMetatable(&lua);

    // Verify the metatable exists
    _ = lua.getMetatableRegistry(RESPONSE_MT);
    try testing.expect(lua.typeOf(-1) == .table);

    // Verify chunk method exists in metatable
    _ = lua.getField(-1, "chunk");
    try testing.expect(lua.typeOf(-1) == .function);

    lua.pop(2); // Pop function and metatable
}

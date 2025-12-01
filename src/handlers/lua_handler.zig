//! Lua API Handler
//!
//! Handles API requests by executing Lua scripts.
//! Supports two execution modes:
//! 1. Context mode (new): Passes httpz Request/Response directly to Lua
//! 2. Legacy mode: Passes extracted request data as a Lua table
//!
//! Context mode is preferred as it provides:
//! - Direct access to httpz.Request and httpz.Response
//! - Per-request context data storage
//! - Ability to set response headers and status from Lua

const std = @import("std");
const httpz = @import("httpz");
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
const KeyValue = lua_mod.KeyValue;
const AppContext = @import("context.zig").AppContext;

const MAX_HEADERS_FOR_LUA = 32; // Maximum number of headers to pass to Lua
const MAX_QUERY_PARAMS_FOR_LUA = 32; // Maximum number of query params to pass to Lua

/// Extract script name from path (/api/test -> test, /api/users -> users)
fn extractScriptName(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "/api/")) {
        const remaining = path[5..]; // Skip "/api/"
        // Handle paths like /api/users/123 -> users
        if (std.mem.indexOfScalar(u8, remaining, '/')) |slash_pos| {
            return remaining[0..slash_pos];
        }
        return remaining;
    }
    return "test";
}

/// Handle Lua API requests using Per-Request Context
/// This is the preferred method for new scripts
pub fn handle(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    if (ctx.lua_handler) |*handler| {
        const script_name = extractScriptName(req.url.path);

        // Execute with context-based API: handle(request, response, context)
        const result = handler.executeScriptWithContext(script_name, "handle", req, res) catch |err| {
            ctx.logger.err("Lua execution error: {}", .{err});
            res.status = 500;
            res.body =
                \\{"status":"error","message":"Script execution failed"}
            ;
            return;
        };

        res.body = result;
    } else {
        res.status = 503;
        res.body =
            \\{"status":"error","message":"Lua handler not initialized"}
        ;
    }
}

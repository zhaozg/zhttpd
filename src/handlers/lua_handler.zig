//! Lua API Handler
//!
//! Handles API requests by executing Lua scripts.
//! Supports two execution modes:
//! 1. Context mode (new): Passes httpz Request/Response directly to Lua
//! 2. Legacy mode: Passes extracted request data as a Lua table
//!
//! Context mode is preferred as it provides:
//! - Direct access to httpz.Request and httpz.Response
//! - Per-request context data storage (ctx.data)
//! - Ability to set response headers and status from Lua

const std = @import("std");
const httpz = @import("httpz");
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
const KeyValue = lua_mod.KeyValue;
const AppContext = @import("httpz_handlers.zig").AppContext;

const MAX_HEADERS_FOR_LUA = 32; // Maximum number of headers to pass to Lua
const MAX_QUERY_PARAMS_FOR_LUA = 32; // Maximum number of query params to pass to Lua

/// Handle Lua API requests using Per-Request Context
/// This is the preferred method for new scripts
pub fn handle(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    if (ctx.lua_handler) |*handler| {
        const path = req.url.path;

        // Extract script name from path (/api/test -> test, /api/users -> users)
        const script_name = blk: {
            if (std.mem.startsWith(u8, path, "/api/")) {
                const remaining = path[5..]; // Skip "/api/"
                // Handle paths like /api/users/123 -> users
                if (std.mem.indexOfScalar(u8, remaining, '/')) |slash_pos| {
                    break :blk remaining[0..slash_pos];
                }
                break :blk remaining;
            }
            break :blk "test";
        };

        // Try context-based execution first (new style)
        // This passes the full httpz Request/Response to Lua
        const result = handler.executeScriptWithContext(script_name, req, res) catch |err| {
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

/// Handle Lua API requests using legacy mode
/// This mode extracts request data and passes it as a Lua table
/// Kept for backward compatibility with existing scripts
pub fn handleLegacy(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    if (ctx.lua_handler) |*handler| {
        const path = req.url.path;
        const method = @tagName(req.method);

        // Extract script name from path (/api/test -> test, /api/users -> users)
        const script_name = blk: {
            if (std.mem.startsWith(u8, path, "/api/")) {
                const remaining = path[5..]; // Skip "/api/"
                // Handle paths like /api/users/123 -> users
                if (std.mem.indexOfScalar(u8, remaining, '/')) |slash_pos| {
                    break :blk remaining[0..slash_pos];
                }
                break :blk remaining;
            }
            break :blk "test";
        };

        // Get request body
        const body = req.body() orelse "";

        // Extract headers for Lua (luvit/Node.js style)
        var headers_buf: [MAX_HEADERS_FOR_LUA]KeyValue = undefined;
        var headers_count: usize = 0;
        var header_iter = req.headers.iterator();
        while (header_iter.next()) |entry| {
            if (headers_count >= MAX_HEADERS_FOR_LUA) break;
            headers_buf[headers_count] = KeyValue{
                .key = entry.key,
                .value = entry.value,
            };
            headers_count += 1;
        }
        const headers = headers_buf[0..headers_count];

        // Extract query parameters for Lua (luvit/Node.js style)
        // Note: URL decoding is not performed here - parameters with encoded
        // characters (like %20 for spaces) will remain encoded. Full URL decoding
        // should be implemented in a future enhancement if needed.
        var query_buf: [MAX_QUERY_PARAMS_FOR_LUA]KeyValue = undefined;
        var query_count: usize = 0;

        // Parse query string from URL if present
        if (req.url.query.len > 0) {
            var query_iter = std.mem.splitScalar(u8, req.url.query, '&');
            while (query_iter.next()) |param| {
                if (query_count >= MAX_QUERY_PARAMS_FOR_LUA) break;
                if (std.mem.indexOfScalar(u8, param, '=')) |eq_pos| {
                    query_buf[query_count] = KeyValue{
                        .key = param[0..eq_pos],
                        .value = if (eq_pos + 1 < param.len) param[eq_pos + 1 ..] else "",
                    };
                    query_count += 1;
                } else if (param.len > 0) {
                    // Handle flag-style parameters (e.g., ?flag&debug)
                    query_buf[query_count] = KeyValue{
                        .key = param,
                        .value = "",
                    };
                    query_count += 1;
                }
            }
        }
        const query_params = query_buf[0..query_count];

        // Use the response arena allocator for per-request allocations
        // This ensures all allocations are automatically cleaned up after the response
        const result = handler.executeScriptEx(res.arena, script_name, method, path, body, headers, query_params) catch |err| {
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

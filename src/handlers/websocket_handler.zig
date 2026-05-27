//! WebSocket Upgrade Handler
//!
//! Handles WebSocket upgrade requests and delegates to WebSocketHandler.

const std = @import("std");
const httpz = @import("httpz");
const lua_mod = @import("../lua/lua.zig");
const LuaHandler = lua_mod.LuaHandler;
const ws_mod = @import("websocket.zig");
const WebSocketHandler = ws_mod.WebSocketHandler;
const WebSocketContext = ws_mod.WebSocketContext;
const AppContext = @import("context.zig").AppContext;

/// Handle WebSocket upgrade requests
pub fn handle(ctx: *AppContext, _req: *httpz.Request, res: *httpz.Response) !void {
    _ = _req;
    ctx.logger.debug("WebSocket upgrade request received", .{});

    // Get a mutable pointer to lua_handler if it exists
    const lua_handler_ptr: ?*LuaHandler = if (ctx.lua_handler != null) blk: {
        // We need to get a pointer to the optional's value
        // This is safe because ctx.lua_handler is stored in AppContext which outlives the request
        break :blk @constCast(&ctx.lua_handler.?);
    } else null;

    // WebSocket upgrade is temporarily disabled due to Zig 0.16 API migration
    _ = lua_handler_ptr;

    // WebSocket upgrade is temporarily disabled due to Zig 0.16 API migration
    // The httpz.upgradeWebsocket function is commented out in the httpz source
    // See: https://github.com/karlseguin/http.zig/issues
    ctx.logger.warn("WebSocket upgrade not available in this build", .{});
    res.status = 501;
    res.body = "{\"error\":\"WebSocket not available\"}";
    res.content_type = httpz.ContentType.JSON;
}

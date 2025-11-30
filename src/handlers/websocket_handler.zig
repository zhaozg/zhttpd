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
pub fn handle(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    ctx.logger.debug("WebSocket upgrade request received", .{});

    // Get a mutable pointer to lua_handler if it exists
    const lua_handler_ptr: ?*LuaHandler = if (ctx.lua_handler != null) blk: {
        // We need to get a pointer to the optional's value
        // This is safe because ctx.lua_handler is stored in AppContext which outlives the request
        break :blk @constCast(&ctx.lua_handler.?);
    } else null;

    // Create WebSocket context with Lua handler
    // Note: The path from req.url.path is stored in WebSocketContext. Since httpz manages
    // the request lifetime and WebSocket connections are handled synchronously within the
    // request context by httpz, the path reference remains valid during the upgrade process.
    // After upgrade, WebSocketHandler stores its own copy of connection metadata.
    const ws_ctx = WebSocketContext.init(req.url.path, lua_handler_ptr);

    // Attempt to upgrade the connection to WebSocket
    if (try httpz.upgradeWebsocket(WebSocketHandler, req, res, &ws_ctx) == false) {
        ctx.logger.warn("WebSocket upgrade failed - invalid request", .{});
        res.status = 400;
        res.body = "{\"error\":\"Invalid WebSocket request\"}";
        res.content_type = httpz.ContentType.JSON;
    } else {
        ctx.logger.info("WebSocket connection established: id={d}, path={s}", .{ ws_ctx.connection_id, req.url.path });
    }
    // After successful upgrade, the request and response are no longer valid
}

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

    // Get a mutable pointer to lua_handler if it exists.
    // This is safe because ctx.lua_handler is stored in AppContext which
    // outlives the request.
    const lua_handler_ptr: ?*LuaHandler = if (ctx.lua_handler != null)
        @constCast(&ctx.lua_handler.?)
    else
        null;

    // Build the context passed to each WebSocket connection handler.
    const ws_ctx = WebSocketContext.init(req.url.path, lua_handler_ptr);

    // Attempt the protocol upgrade. Returns false when the request is not a
    // valid WebSocket handshake (e.g. a plain GET), in which case we respond
    // with a 400 Bad Request.
    const upgraded = httpz.upgradeWebsocket(WebSocketHandler, req, res, &ws_ctx) catch |err| {
        ctx.logger.warn("WebSocket upgrade failed: {}", .{err});
        res.status = 500;
        res.body = "{\"error\":\"WebSocket upgrade failed\"}";
        res.content_type = httpz.ContentType.JSON;
        return;
    };

    if (!upgraded) {
        res.status = 400;
        res.body = "{\"error\":\"Invalid WebSocket handshake\"}";
        res.content_type = httpz.ContentType.JSON;
        return;
    }

    // On success httpz has taken over the connection; nothing else to do.
}

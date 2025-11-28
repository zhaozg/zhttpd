//! SSE (Server-Sent Events) Handler
//!
//! Handles SSE connections for real-time event streaming.

const std = @import("std");
const httpz = @import("httpz");

/// Handle SSE requests
pub fn handle(ctx_ptr: *anyopaque, _: *httpz.Request, res: *httpz.Response) !void {
    const ctx = @as(*@import("httpz_handlers.zig").AppContext, @ptrCast(@alignCast(ctx_ptr)));

    ctx.logger.debug("SSE connection established from client", .{});

    // Start event stream (synchronous mode for simpler handling)
    const stream = res.startEventStreamSync() catch |err| {
        ctx.logger.err("Failed to start SSE stream: {}", .{err});
        res.status = 500;
        res.body = "Failed to start event stream";
        return;
    };

    // Send a welcome event
    _ = stream.write("event: connected\ndata: {\"status\":\"connected\",\"message\":\"SSE stream established\"}\n\n") catch |err| {
        ctx.logger.warn("Failed to write SSE welcome event: {}", .{err});
        return;
    };

    // Send a heartbeat event with actual timestamp
    var heartbeat_buf: [128]u8 = undefined;
    const timestamp = std.time.timestamp();
    const heartbeat_data = std.fmt.bufPrint(&heartbeat_buf, "event: heartbeat\ndata: {{\"timestamp\":{d}}}\n\n", .{timestamp}) catch {
        ctx.logger.warn("Failed to format SSE heartbeat", .{});
        return;
    };
    _ = stream.write(heartbeat_data) catch |err| {
        ctx.logger.warn("Failed to write SSE heartbeat: {}", .{err});
        return;
    };

    ctx.logger.debug("SSE events sent successfully", .{});
}

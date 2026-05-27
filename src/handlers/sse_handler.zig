//! SSE (Server-Sent Events) Handler
//!
//! Handles SSE connections for real-time event streaming.

const std = @import("std");
const httpz = @import("httpz");
const AppContext = @import("context.zig").AppContext;

/// Handle SSE requests
pub fn handle(ctx: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    ctx.logger.debug("SSE connection established from client", .{});

    // Start event stream (synchronous mode for simpler handling)
    const stream = res.startEventStreamSync() catch |err| {
        ctx.logger.@"error"("Failed to start SSE stream: {}", .{err});
        res.status = 500;
        res.body = "Failed to start event stream";
        return;
    };

    const io = res.conn.io;
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    // Send a welcome event
    writer.interface.writeAll("event: connected\ndata: {\"status\":\"connected\",\"message\":\"SSE stream established\"}\n\n") catch |err| {
        ctx.logger.warn("Failed to write SSE welcome event: {}", .{err});
        return;
    };

    // Send a heartbeat event with actual timestamp
    var heartbeat_buf: [128]u8 = undefined;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const timestamp = ts.sec;
    const heartbeat_data = std.fmt.bufPrint(&heartbeat_buf, "event: heartbeat\ndata: {{\"timestamp\":{d}}}\n\n", .{timestamp}) catch {
        ctx.logger.warn("Failed to format SSE heartbeat", .{});
        return;
    };
    writer.interface.writeAll(heartbeat_data) catch |err| {
        ctx.logger.warn("Failed to write SSE heartbeat: {}", .{err});
        return;
    };

    ctx.logger.debug("SSE events sent successfully", .{});
}

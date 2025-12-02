//! GraphQL Handler
//!
//! Handles GraphQL queries via GET and POST requests.
//! Supports Lua-based resolvers and the GraphQL Playground UI.

const std = @import("std");
const httpz = @import("httpz");
const AppContext = @import("context.zig").AppContext;

/// Handle GraphQL GET requests
pub fn handleGet(ctx: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    _ = ctx;
    res.content_type = httpz.ContentType.JSON;
    res.body =
        \\{"data":{"message":"GraphQL endpoint - use POST for queries"}}
    ;
}

/// Handle GraphQL POST requests
pub fn handlePost(ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    if (ctx.graphql_handler) |*handler| {
        // Get request body
        const body = req.body() orelse {
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Missing request body"}]}
            ;
            return;
        };

        // Parse JSON body
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch |err| {
            ctx.logger.err("GraphQL JSON parse error: {}", .{err});
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Invalid JSON in request body"}]}
            ;
            return;
        };
        // No defer needed for arena-allocated memory

        // Extract query field with type checking
        const query = if (parsed.value.object.get("query")) |q| blk: {
            if (q != .string) {
                res.status = 400;
                res.body =
                    \\{"errors":[{"message":"'query' field must be a string"}]}
                ;
                return;
            }
            break :blk q.string;
        } else {
            res.status = 400;
            res.body =
                \\{"errors":[{"message":"Missing 'query' field"}]}
            ;
            return;
        };

        // Phase 2: If Lua handler is available, delegate to Lua resolver
        if (ctx.lua_handler) |*lua_handler| {
            // Execute Lua graphql resolver script
            // The Lua script will have access to req.body() which contains the GraphQL query JSON
            const result = lua_handler.executeScriptWithContext("graphql", "handle_request", req, res) catch |err| {
                // If graphql.lua doesn't exist, fall back to default handler
                if (err == error.InvalidScriptName or err == error.FileNotFound) {
                    const default_result = handler.executeQuery(res.arena, query) catch {
                        res.status = 500;
                        res.body =
                            \\{"errors":[{"message":"Query execution failed"}]}
                        ;
                        return;
                    };
                    res.body = default_result;
                    return;
                }
                ctx.logger.err("GraphQL Lua resolver error: {}", .{err});
                res.status = 500;
                res.body =
                    \\{"errors":[{"message":"Resolver execution failed"}]}
                ;
                return;
            };

            res.body = result;
        } else {
            // No Lua handler, use default execution
            const result = handler.executeQuery(res.arena, query) catch {
                res.status = 500;
                res.body =
                    \\{"errors":[{"message":"Query execution failed"}]}
                ;
                return;
            };
            res.body = result;
        }
    } else {
        res.status = 503;
        res.body =
            \\{"errors":[{"message":"GraphQL handler not initialized"}]}
        ;
    }
}

/// Handle GraphQL Playground UI requests
pub fn handlePlayground(ctx: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.HTML;

    if (ctx.graphql_handler) |*handler| {
        const html = handler.getPlaygroundHtml(res.arena, ctx.config.graphql_endpoint) catch {
            res.status = 500;
            res.body = "Failed to generate playground HTML";
            return;
        };
        res.body = html;
    } else {
        res.status = 503;
        res.body = "GraphQL handler not initialized";
    }
}

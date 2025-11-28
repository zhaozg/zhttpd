//! GraphQL Handler
//!
//! Handles GraphQL queries via GET and POST requests.
//! Supports Lua-based resolvers and the GraphQL Playground UI.

const std = @import("std");
const httpz = @import("httpz");
const AppContext = @import("httpz_handlers.zig").AppContext;

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

        // Extract variables field (optional) and serialize to JSON string
        const variables = if (parsed.value.object.get("variables")) |v| blk: {
            // Serialize variables to JSON string using std.json.Stringify
            const serialized = std.json.Stringify.valueAlloc(res.arena, v, .{}) catch {
                break :blk "{}";
            };
            break :blk serialized;
        } else "{}";

        // Phase 2: If Lua handler is available, delegate to Lua resolver
        if (ctx.lua_handler) |*lua_handler| {
            // Parse the GraphQL query first
            var parsed_op = handler.parseQuery(res.arena, query) catch |err| {
                res.body = std.fmt.allocPrint(res.arena,
                    \\{{"errors":[{{"message":"Parse error: {s}"}}]}}
                , .{@errorName(err)}) catch
                    \\{"errors":[{"message":"Parse error"}]}
                ;
                return;
            };
            defer parsed_op.deinit(res.arena);

            // Convert operation to JSON for Lua
            const op_json = handler.operationToJson(res.arena, &parsed_op) catch {
                res.status = 500;
                res.body =
                    \\{"errors":[{"message":"Failed to serialize operation"}]}
                ;
                return;
            };

            // Build request data with operation and variables
            // We only pass the parsed operation JSON, since the original query string from the request may contain unescaped quotes
            const request_data = std.fmt.allocPrint(res.arena,
                \\{{"operation":{s},"variables":{s}}}
            , .{ op_json, variables }) catch {
                res.status = 500;
                res.body =
                    \\{"errors":[{"message":"Failed to build request"}]}
                ;
                return;
            };

            // Execute Lua graphql resolver script
            const result = lua_handler.executeScript(res.arena, "graphql", "POST", "/graphql", request_data) catch |err| {
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

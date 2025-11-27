const std = @import("std");
const grapzig = @import("grapzig");

// GraphQL integration module
// This module provides GraphQL API capabilities
// Based on grapzig: https://github.com/yousif-wali/grapzig
//
// Phase 2 Full GraphQL Implementation:
// - Uses grapzig Parser to parse GraphQL queries
// - Delegates execution (Step 5) and response building (Step 6) to Lua resolvers
// - Provides general resolver API for Lua-based data fetching

/// Helper function to write a JSON-escaped string
fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Control character - write as \u00XX
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Parsed selection field for Lua resolver
pub const SelectionField = struct {
    name: []const u8,
    alias: ?[]const u8,
    arguments: std.StringHashMap(grapzig.Value),
    sub_selections: std.ArrayList(SelectionField),

    pub fn init(allocator: std.mem.Allocator) SelectionField {
        return .{
            .name = "",
            .alias = null,
            .arguments = std.StringHashMap(grapzig.Value).init(allocator),
            .sub_selections = std.ArrayList(SelectionField){},
        };
    }

    pub fn deinit(self: *SelectionField, allocator: std.mem.Allocator) void {
        for (self.sub_selections.items) |*sub| {
            sub.deinit(allocator);
        }
        self.sub_selections.deinit(allocator);
        self.arguments.deinit();
    }
};

/// Parsed GraphQL operation for Lua resolver
pub const ParsedOperation = struct {
    operation_type: OperationType,
    name: ?[]const u8,
    selections: std.ArrayList(SelectionField),

    pub const OperationType = enum {
        query,
        mutation,
        subscription,
    };

    pub fn init(_: std.mem.Allocator) ParsedOperation {
        return .{
            .operation_type = .query,
            .name = null,
            .selections = std.ArrayList(SelectionField){},
        };
    }

    pub fn deinit(self: *ParsedOperation, allocator: std.mem.Allocator) void {
        for (self.selections.items) |*sel| {
            sel.deinit(allocator);
        }
        self.selections.deinit(allocator);
    }
};

/// Resolver function signature for Lua-based resolvers
/// The resolver receives operation info as JSON and returns JSON response
pub const ResolverFn = *const fn (
    allocator: std.mem.Allocator,
    operation_json: []const u8,
) anyerror![]const u8;

pub const GraphQLHandler = struct {
    allocator: std.mem.Allocator,
    schema: ?[]const u8,
    resolver: ?ResolverFn,

    pub fn init(allocator: std.mem.Allocator) !GraphQLHandler {
        return GraphQLHandler{
            .allocator = allocator,
            .schema = null,
            .resolver = null,
        };
    }

    pub fn deinit(self: *GraphQLHandler) void {
        if (self.schema) |schema| {
            self.allocator.free(schema);
        }
    }

    /// Set Lua resolver function for query execution
    pub fn setResolver(self: *GraphQLHandler, resolver: ResolverFn) void {
        self.resolver = resolver;
    }

    pub fn loadSchema(self: *GraphQLHandler, schema_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(schema_path, .{});
        defer file.close();

        const schema = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        self.schema = schema;
    }

    /// Parse a GraphQL query and return parsed operation info
    /// This is Step 3: grapzig.Parser.parse(query_string)
    pub fn parseQuery(self: *GraphQLHandler, arena: std.mem.Allocator, query: []const u8) !ParsedOperation {
        _ = self;
        var parser = grapzig.Parser.init(arena, query);
        var document = try parser.parse();
        defer document.deinit();

        // Extract the first operation (simplified - real implementation would handle multiple)
        if (document.definitions.items.len == 0) {
            return error.NoOperationFound;
        }

        const def = document.definitions.items[0];
        switch (def) {
            .operation => |op| {
                var parsed_op = ParsedOperation.init(arena);
                parsed_op.operation_type = switch (op.operation_type) {
                    .query => .query,
                    .mutation => .mutation,
                    .subscription => .subscription,
                };
                parsed_op.name = op.name;

                // Convert selections
                for (op.selections.items) |sel| {
                    const field = try convertSelection(arena, sel);
                    try parsed_op.selections.append(arena, field);
                }

                return parsed_op;
            },
        }
    }

    fn convertSelection(allocator: std.mem.Allocator, sel: grapzig.Selection) !SelectionField {
        var field = SelectionField.init(allocator);
        field.name = sel.name;
        field.alias = sel.alias;
        field.arguments = sel.arguments;

        // Convert sub-selections
        for (sel.selections.items) |sub_sel| {
            const sub_field = try convertSelection(allocator, sub_sel);
            try field.sub_selections.append(allocator, sub_field);
        }

        return field;
    }

    /// Convert parsed operation to JSON for Lua resolver
    pub fn operationToJson(self: *GraphQLHandler, arena: std.mem.Allocator, op: *const ParsedOperation) ![]const u8 {
        _ = self;
        var buf = std.ArrayList(u8){};
        defer buf.deinit(arena);

        const writer = buf.writer(arena);
        try writer.writeAll("{\"operation_type\":\"");
        try writer.writeAll(switch (op.operation_type) {
            .query => "query",
            .mutation => "mutation",
            .subscription => "subscription",
        });
        try writer.writeAll("\"");

        if (op.name) |name| {
            try writer.writeAll(",\"name\":");
            try writeJsonEscapedString(writer, name);
        }

        try writer.writeAll(",\"selections\":[");
        for (op.selections.items, 0..) |sel, i| {
            if (i > 0) try writer.writeByte(',');
            try writeSelectionJson(writer, &sel);
        }
        try writer.writeAll("]}");

        return try buf.toOwnedSlice(arena);
    }

    fn writeSelectionJson(writer: anytype, sel: *const SelectionField) !void {
        try writer.writeAll("{\"name\":");
        try writeJsonEscapedString(writer, sel.name);

        if (sel.alias) |alias| {
            try writer.writeAll(",\"alias\":");
            try writeJsonEscapedString(writer, alias);
        }

        // Write arguments
        if (sel.arguments.count() > 0) {
            try writer.writeAll(",\"arguments\":{");
            var iter = sel.arguments.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeJsonEscapedString(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                try entry.value_ptr.toJson(writer);
            }
            try writer.writeByte('}');
        }

        // Write sub-selections
        if (sel.sub_selections.items.len > 0) {
            try writer.writeAll(",\"selections\":[");
            for (sel.sub_selections.items, 0..) |sub_sel, i| {
                if (i > 0) try writer.writeByte(',');
                try writeSelectionJson(writer, &sub_sel);
            }
            try writer.writeByte(']');
        }

        try writer.writeByte('}');
    }

    /// Execute a GraphQL query
    /// Steps 3-6 of the GraphQL execution flow:
    /// 3. Parse query with grapzig
    /// 4. (Optional) Validate against schema
    /// 5. Execute query via Lua resolver
    /// 6. Build JSON response (done in Lua)
    pub fn executeQuery(self: *GraphQLHandler, arena: std.mem.Allocator, query: []const u8) ![]const u8 {
        if (self.schema == null) {
            return try arena.dupe(u8,
                \\{"errors":[{"message":"Schema not loaded"}]}
            );
        }

        // Step 3: Parse query
        var parsed_op = self.parseQuery(arena, query) catch |err| {
            return try std.fmt.allocPrint(arena,
                \\{{"errors":[{{"message":"Parse error: {s}"}}]}}
            , .{@errorName(err)});
        };
        defer parsed_op.deinit(arena);

        // Step 5 & 6: Execute via Lua resolver if set
        if (self.resolver) |resolver| {
            const op_json = try self.operationToJson(arena, &parsed_op);
            return try resolver(arena, op_json);
        }

        // Default response if no resolver is set (for basic testing)
        return try self.buildDefaultResponse(arena, &parsed_op);
    }

    /// Build default response when no Lua resolver is set
    fn buildDefaultResponse(self: *GraphQLHandler, arena: std.mem.Allocator, op: *const ParsedOperation) ![]const u8 {
        _ = self;
        var buf = std.ArrayList(u8){};
        defer buf.deinit(arena);

        const writer = buf.writer(arena);
        try writer.writeAll("{\"data\":{");

        for (op.selections.items, 0..) |sel, i| {
            if (i > 0) try writer.writeByte(',');
            const name = sel.alias orelse sel.name;
            try writeJsonEscapedString(writer, name);
            try writer.writeAll(":null");
        }

        try writer.writeAll("}}");
        return try buf.toOwnedSlice(arena);
    }

    pub fn executeMutation(self: *GraphQLHandler, arena: std.mem.Allocator, mutation: []const u8) ![]const u8 {
        // Mutations are just queries in GraphQL, use the same execution path
        return try self.executeQuery(arena, mutation);
    }

    /// Get GraphQL Playground HTML
    pub fn getPlaygroundHtml(self: *GraphQLHandler, arena: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
        _ = self;
        return try std.fmt.allocPrint(arena,
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>GraphQL Playground - zhttpd</title>
            \\  <style>
            \\    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
            \\    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #1e1e2e; color: #cdd6f4; min-height: 100vh; }}
            \\    .header {{ background: #313244; padding: 1rem 2rem; border-bottom: 1px solid #45475a; }}
            \\    .header h1 {{ font-size: 1.5rem; color: #89b4fa; }}
            \\    .container {{ display: grid; grid-template-columns: 1fr 1fr; height: calc(100vh - 60px); }}
            \\    .panel {{ padding: 1rem; display: flex; flex-direction: column; }}
            \\    .panel-header {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }}
            \\    .panel-title {{ font-size: 0.875rem; color: #a6adc8; text-transform: uppercase; letter-spacing: 0.05em; }}
            \\    textarea {{ flex: 1; background: #181825; border: 1px solid #45475a; border-radius: 8px; padding: 1rem; font-family: 'Fira Code', 'Monaco', monospace; font-size: 14px; color: #cdd6f4; resize: none; }}
            \\    textarea:focus {{ outline: none; border-color: #89b4fa; }}
            \\    .btn {{ background: #89b4fa; color: #1e1e2e; border: none; padding: 0.5rem 1rem; border-radius: 6px; cursor: pointer; font-weight: 600; transition: background 0.2s; }}
            \\    .btn:hover {{ background: #b4befe; }}
            \\    .btn:disabled {{ background: #45475a; cursor: not-allowed; }}
            \\    #response {{ background: #181825; white-space: pre-wrap; overflow: auto; }}
            \\    .error {{ color: #f38ba8; }}
            \\    .loading {{ color: #a6adc8; font-style: italic; }}
            \\    .variables-section {{ margin-top: 1rem; }}
            \\    .variables-section textarea {{ height: 100px; flex: none; }}
            \\    .divider {{ width: 1px; background: #45475a; }}
            \\  </style>
            \\</head>
            \\<body>
            \\  <div class="header">
            \\    <h1>GraphQL Playground</h1>
            \\  </div>
            \\  <div class="container">
            \\    <div class="panel">
            \\      <div class="panel-header">
            \\        <span class="panel-title">Query</span>
            \\        <button class="btn" onclick="executeQuery()">Execute</button>
            \\      </div>
            \\      <textarea id="query" placeholder="Enter your GraphQL query...">query {{
            \\  hello
            \\  users {{
            \\    id
            \\    name
            \\    email
            \\  }}
            \\}}</textarea>
            \\      <div class="variables-section">
            \\        <div class="panel-header">
            \\          <span class="panel-title">Variables (JSON)</span>
            \\        </div>
            \\        <textarea id="variables" placeholder='{{"key": "value"}}'>{{}}</textarea>
            \\      </div>
            \\    </div>
            \\    <div class="divider"></div>
            \\    <div class="panel">
            \\      <div class="panel-header">
            \\        <span class="panel-title">Response</span>
            \\      </div>
            \\      <textarea id="response" readonly placeholder="Response will appear here..."></textarea>
            \\    </div>
            \\  </div>
            \\  <script>
            \\    async function executeQuery() {{
            \\      const query = document.getElementById('query').value;
            \\      const variablesText = document.getElementById('variables').value;
            \\      const responseEl = document.getElementById('response');
            \\      
            \\      let variables = {{}};
            \\      try {{
            \\        variables = JSON.parse(variablesText);
            \\      }} catch (e) {{
            \\        responseEl.value = 'Invalid JSON in variables';
            \\        responseEl.classList.add('error');
            \\        return;
            \\      }}
            \\      
            \\      responseEl.value = 'Loading...';
            \\      responseEl.classList.remove('error');
            \\      responseEl.classList.add('loading');
            \\      
            \\      try {{
            \\        const response = await fetch('{s}', {{
            \\          method: 'POST',
            \\          headers: {{ 'Content-Type': 'application/json' }},
            \\          body: JSON.stringify({{ query, variables }})
            \\        }});
            \\        const data = await response.json();
            \\        responseEl.classList.remove('loading');
            \\        responseEl.value = JSON.stringify(data, null, 2);
            \\        if (data.errors) {{
            \\          responseEl.classList.add('error');
            \\        }}
            \\      }} catch (error) {{
            \\        responseEl.classList.remove('loading');
            \\        responseEl.classList.add('error');
            \\        responseEl.value = 'Network error: ' + error.message;
            \\      }}
            \\    }}
            \\    
            \\    // Execute on Ctrl+Enter
            \\    document.getElementById('query').addEventListener('keydown', function(e) {{
            \\      if (e.ctrlKey && e.key === 'Enter') {{
            \\        executeQuery();
            \\      }}
            \\    }});
            \\  </script>
            \\</body>
            \\</html>
        , .{endpoint});
    }
};

test "graphql handler init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var handler = try GraphQLHandler.init(allocator);
    defer handler.deinit();

    // Test basic query execution without schema (should return error)
    const result = try handler.executeQuery(allocator, "{ hello }");
    // Arena allocator would normally clean this up, but in tests we use testing.allocator
    defer allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "Schema not loaded") != null);
}

test "graphql parse query" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var handler = try GraphQLHandler.init(testing.allocator);
    defer handler.deinit();
    handler.schema = "type Query { hello: String }";

    // Test parsing a simple query
    var parsed = try handler.parseQuery(allocator, "query { hello }");
    defer parsed.deinit(allocator);

    try testing.expect(parsed.operation_type == .query);
    try testing.expect(parsed.selections.items.len == 1);
    try testing.expectEqualStrings("hello", parsed.selections.items[0].name);
}

test "graphql parse query with arguments" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var handler = try GraphQLHandler.init(testing.allocator);
    defer handler.deinit();
    handler.schema = "type Query { user(id: ID!): User }";

    // Test parsing a query with arguments
    var parsed = try handler.parseQuery(allocator, "query { user(id: \"123\") { name email } }");
    defer parsed.deinit(allocator);

    try testing.expect(parsed.operation_type == .query);
    try testing.expect(parsed.selections.items.len == 1);

    const user_sel = &parsed.selections.items[0];
    try testing.expectEqualStrings("user", user_sel.name);
    try testing.expect(user_sel.arguments.count() == 1);
    try testing.expect(user_sel.sub_selections.items.len == 2);
}

test "graphql operation to json" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var handler = try GraphQLHandler.init(testing.allocator);
    defer handler.deinit();
    handler.schema = "type Query { hello: String }";

    var parsed = try handler.parseQuery(allocator, "query { hello }");
    defer parsed.deinit(allocator);

    const json = try handler.operationToJson(allocator, &parsed);
    try testing.expect(std.mem.indexOf(u8, json, "\"operation_type\":\"query\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"hello\"") != null);
}

test "graphql execute with schema" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var handler = try GraphQLHandler.init(testing.allocator);
    defer handler.deinit();

    // Load a simple schema
    handler.schema = try testing.allocator.dupe(u8, "type Query { hello: String }");

    const result = try handler.executeQuery(allocator, "query { hello }");
    try testing.expect(result.len > 0);
    // Should return default response with null data
    try testing.expect(std.mem.indexOf(u8, result, "\"data\"") != null);
}

test "graphql playground html" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var handler = try GraphQLHandler.init(testing.allocator);
    defer handler.deinit();

    const html = try handler.getPlaygroundHtml(allocator, "/graphql");
    try testing.expect(std.mem.indexOf(u8, html, "GraphQL Playground") != null);
    try testing.expect(std.mem.indexOf(u8, html, "/graphql") != null);
}

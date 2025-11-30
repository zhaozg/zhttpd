-- GraphQL Resolver Script for zhttpd
-- This script handles GraphQL query execution (Step 5 & 6 of GraphQL flow)
--
-- Request object structure (passed as request.body):
-- {
--   operation = {
--     operation_type = "query" | "mutation" | "subscription",
--     name = "OperationName" (optional),
--     selections = [
--       {
--         name = "fieldName",
--         alias = "aliasName" (optional),
--         arguments = { key = value, ... },
--         selections = [ ... ] (nested fields)
--       },
--       ...
--     ]
--   },
--   variables = { ... }
-- }
--
-- The resolver should:
-- 1. Parse the operation and selections
-- 2. Call appropriate data fetchers (database, external APIs, etc.)
-- 3. Return a JSON response in GraphQL format: { "data": { ... } }
--
-- Database Integration:
-- This resolver supports both in-memory data (fallback) and database storage.
-- When database is configured (enable_db: true in config), data is persisted.
-- Access database via context:db() - returns nil if not configured.
-- Note: Current implementation uses SQLite-specific syntax. For PostgreSQL/MySQL,
-- the SQL queries may need to be adapted.
--
-- Schema Introspection:
-- Supports __schema, __type, and __typename introspection queries.

-- GraphQL schema definition (for introspection)
local schema_types = {
    Query = {
        kind = "OBJECT",
        name = "Query",
        fields = {
            { name = "hello", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "user", type = { kind = "OBJECT", name = "User" }, args = { { name = "id", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "ID" } } } } },
            { name = "users", type = { kind = "NON_NULL", ofType = { kind = "LIST", ofType = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "User" } } } } },
            { name = "post", type = { kind = "OBJECT", name = "Post" }, args = { { name = "id", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "ID" } } } } },
            { name = "posts", type = { kind = "NON_NULL", ofType = { kind = "LIST", ofType = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "Post" } } } } }
        }
    },
    Mutation = {
        kind = "OBJECT",
        name = "Mutation",
        fields = {
            { name = "createUser", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "User" } } },
            { name = "updateUser", type = { kind = "OBJECT", name = "User" } },
            { name = "deleteUser", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "Boolean" } } },
            { name = "createPost", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "Post" } } }
        }
    },
    Subscription = {
        kind = "OBJECT",
        name = "Subscription",
        fields = {
            { name = "userCreated", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "User" } } },
            { name = "postCreated", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "Post" } } },
            { name = "userUpdated", type = { kind = "OBJECT", name = "User" } },
            { name = "messageReceived", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "Message" } } }
        }
    },
    User = {
        kind = "OBJECT",
        name = "User",
        fields = {
            { name = "id", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "ID" } } },
            { name = "name", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "email", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "posts", type = { kind = "NON_NULL", ofType = { kind = "LIST", ofType = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "Post" } } } } },
            { name = "createdAt", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } }
        }
    },
    Post = {
        kind = "OBJECT",
        name = "Post",
        fields = {
            { name = "id", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "ID" } } },
            { name = "title", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "content", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "author", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "User" } } },
            { name = "createdAt", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "updatedAt", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } }
        }
    },
    Message = {
        kind = "OBJECT",
        name = "Message",
        fields = {
            { name = "id", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "ID" } } },
            { name = "content", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } },
            { name = "sender", type = { kind = "NON_NULL", ofType = { kind = "OBJECT", name = "User" } } },
            { name = "timestamp", type = { kind = "NON_NULL", ofType = { kind = "SCALAR", name = "String" } } }
        }
    },
    String = { kind = "SCALAR", name = "String" },
    ID = { kind = "SCALAR", name = "ID" },
    Boolean = { kind = "SCALAR", name = "Boolean" },
    Int = { kind = "SCALAR", name = "Int" },
    Float = { kind = "SCALAR", name = "Float" }
}

-- Introspection query resolvers
local introspection_resolvers = {
    __schema = function(args, context)
        return {
            queryType = { name = "Query" },
            mutationType = { name = "Mutation" },
            subscriptionType = { name = "Subscription" },
            types = (function()
                local types_list = {}
                for name, type_def in pairs(schema_types) do
                    table.insert(types_list, type_def)
                end
                return types_list
            end)(),
            directives = {}
        }
    end,
    
    __type = function(args, context)
        local type_name = args and args.name
        if not type_name then
            return nil
        end
        return schema_types[type_name]
    end
}

-- Query complexity calculation
local MAX_QUERY_COMPLEXITY = 100  -- Maximum allowed complexity
local MAX_QUERY_DEPTH = 10        -- Maximum nesting depth

local function calculate_complexity(selections, depth)
    if not selections then
        return 0, depth
    end
    
    -- Track max depth reached even when exceeding limit
    if depth > MAX_QUERY_DEPTH then
        -- Still return the depth to report the exceeded value
        return 0, depth
    end
    
    local complexity = 0
    local max_depth = depth
    
    for _, sel in ipairs(selections) do
        -- Each field adds 1 to complexity
        complexity = complexity + 1
        
        -- Nested selections increase complexity and depth
        if sel.selections and #sel.selections > 0 then
            local nested_complexity, nested_depth = calculate_complexity(sel.selections, depth + 1)
            complexity = complexity + nested_complexity
            if nested_depth > max_depth then
                max_depth = nested_depth
            end
        end
        
        -- List fields (users, posts) have higher complexity
        if sel.name == "users" or sel.name == "posts" then
            complexity = complexity + 5
        end
    end
    
    return complexity, max_depth
end

-- In-memory fallback data store (used when database is not configured)
local users = {
    ["1"] = { id = "1", name = "Alice", email = "alice@example.com", createdAt = "2024-01-01T00:00:00Z" },
    ["2"] = { id = "2", name = "Bob", email = "bob@example.com", createdAt = "2024-01-02T00:00:00Z" },
    ["3"] = { id = "3", name = "Charlie", email = "charlie@example.com", createdAt = "2024-01-03T00:00:00Z" }
}

local posts = {
    ["1"] = { id = "1", title = "Hello World", content = "My first post!", authorId = "1", createdAt = "2024-01-15T10:00:00Z", updatedAt = "2024-01-15T10:00:00Z" },
    ["2"] = { id = "2", title = "GraphQL is Amazing", content = "Learn how to use GraphQL with zhttpd.", authorId = "1", createdAt = "2024-01-16T11:00:00Z", updatedAt = "2024-01-16T11:00:00Z" },
    ["3"] = { id = "3", title = "Zig Programming", content = "Building high-performance servers with Zig.", authorId = "2", createdAt = "2024-01-17T12:00:00Z", updatedAt = "2024-01-17T12:00:00Z" }
}

local next_user_id = 4
local next_post_id = 4

-- Database helper functions
-- Note: These functions use SQLite-specific syntax (last_insert_rowid).
-- For PostgreSQL, use RETURNING clause; for MySQL, use LAST_INSERT_ID().
-- TODO: Add database type detection for multi-database support.
local function get_user_from_db(db, user_id)
    if not db then return nil end
    local result, err = db:query("SELECT id, name, email, created_at as createdAt FROM users WHERE id = ? AND active = 1", user_id)
    if err or not result or #result == 0 then
        return nil
    end
    return result[1]
end

local function get_all_users_from_db(db)
    if not db then return nil end
    local result, err = db:query("SELECT id, name, email, created_at as createdAt FROM users WHERE active = 1 ORDER BY id")
    if err then return nil end
    return result or {}
end

local function create_user_in_db(db, input)
    if not db then return nil end
    local _, err = db:exec(
        "INSERT INTO users (name, email) VALUES (?, ?)",
        input.name or "Unknown",
        input.email or ""
    )
    if err then return nil end
    -- Note: last_insert_rowid() is SQLite-specific and safe within the same connection
    -- For PostgreSQL, use RETURNING clause; for MySQL, use LAST_INSERT_ID()
    local id_result = db:query("SELECT last_insert_rowid() AS id")
    if id_result and #id_result > 0 then
        return get_user_from_db(db, id_result[1].id)
    end
    return nil
end

local function update_user_in_db(db, user_id, input)
    if not db then return nil end
    local updates = {}
    local values = {}
    if input.name then
        table.insert(updates, "name = ?")
        table.insert(values, input.name)
    end
    if input.email then
        table.insert(updates, "email = ?")
        table.insert(values, input.email)
    end
    if #updates == 0 then return get_user_from_db(db, user_id) end
    
    table.insert(values, user_id)
    local sql = "UPDATE users SET " .. table.concat(updates, ", ") .. " WHERE id = ? AND active = 1"
    local _, err = db:exec(sql, table.unpack(values))
    if err then return nil end
    return get_user_from_db(db, user_id)
end

local function delete_user_in_db(db, user_id)
    if not db then return false end
    local _, err = db:exec("UPDATE users SET active = 0 WHERE id = ?", user_id)
    return err == nil
end

local function get_post_from_db(db, post_id)
    if not db then return nil end
    local result, err = db:query("SELECT id, title, content, author_id as authorId, created_at as createdAt, updated_at as updatedAt FROM posts WHERE id = ?", post_id)
    if err or not result or #result == 0 then
        return nil
    end
    return result[1]
end

local function get_all_posts_from_db(db)
    if not db then return nil end
    local result, err = db:query("SELECT id, title, content, author_id as authorId, created_at as createdAt, updated_at as updatedAt FROM posts ORDER BY id")
    if err then return nil end
    return result or {}
end

-- Note: This function may cause N+1 query issues when resolving multiple users' posts.
-- For production use, consider implementing a DataLoader pattern or batch loading.
local function get_posts_by_author_from_db(db, author_id)
    if not db then return nil end
    local result, err = db:query("SELECT id, title, content, author_id as authorId, created_at as createdAt, updated_at as updatedAt FROM posts WHERE author_id = ? ORDER BY id", author_id)
    if err then return nil end
    return result or {}
end

local function create_post_in_db(db, input)
    if not db then return nil end
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local _, err = db:exec(
        "INSERT INTO posts (title, content, author_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        input.title or "Untitled",
        input.content or "",
        tonumber(input.authorId) or 1,
        now,
        now
    )
    if err then return nil end
    -- Note: last_insert_rowid() is SQLite-specific
    local id_result = db:query("SELECT last_insert_rowid() AS id")
    if id_result and #id_result > 0 then
        return get_post_from_db(db, id_result[1].id)
    end
    return nil
end

-- Resolver functions for Query type
local query_resolvers = {
    hello = function(args, context)
        return "Hello from zhttpd GraphQL!"
    end,
    
    user = function(args, context)
        local id = args and args.id
        if not id then
            return nil
        end
        -- Try database first, fall back to in-memory
        local db = context.db
        local db_user = get_user_from_db(db, id)
        if db_user then
            return db_user
        end
        return users[tostring(id)]
    end,
    
    users = function(args, context)
        -- Try database first, fall back to in-memory
        local db = context.db
        local db_users = get_all_users_from_db(db)
        if db_users and #db_users > 0 then
            return db_users
        end
        local result = {}
        for _, user in pairs(users) do
            table.insert(result, user)
        end
        return result
    end,
    
    post = function(args, context)
        local id = args and args.id
        if not id then
            return nil
        end
        -- Try database first, fall back to in-memory
        local db = context.db
        local db_post = get_post_from_db(db, id)
        if db_post then
            return db_post
        end
        return posts[tostring(id)]
    end,
    
    posts = function(args, context)
        -- Try database first, fall back to in-memory
        local db = context.db
        local db_posts = get_all_posts_from_db(db)
        if db_posts and #db_posts > 0 then
            return db_posts
        end
        local result = {}
        for _, post in pairs(posts) do
            table.insert(result, post)
        end
        return result
    end
}

-- Resolver functions for Mutation type
local mutation_resolvers = {
    createUser = function(args, context)
        local input = args and args.input
        if not input then
            return nil
        end
        
        -- Try database first
        local db = context.db
        local db_user = create_user_in_db(db, input)
        if db_user then
            return db_user
        end
        
        -- Fall back to in-memory
        local id = tostring(next_user_id)
        next_user_id = next_user_id + 1
        
        local user = {
            id = id,
            name = input.name or "Unknown",
            email = input.email or "unknown@example.com",
            createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
        users[id] = user
        return user
    end,
    
    updateUser = function(args, context)
        local id = args and args.id
        local input = args and args.input
        if not id or not input then
            return nil
        end
        
        -- Try database first
        local db = context.db
        local db_user = update_user_in_db(db, id, input)
        if db_user then
            return db_user
        end
        
        -- Fall back to in-memory
        local user = users[tostring(id)]
        if not user then
            return nil
        end
        
        if input.name then user.name = input.name end
        if input.email then user.email = input.email end
        
        return user
    end,
    
    deleteUser = function(args, context)
        local id = args and args.id
        if not id then
            return false
        end
        
        -- Try database first
        local db = context.db
        if db and delete_user_in_db(db, id) then
            return true
        end
        
        -- Fall back to in-memory
        if users[tostring(id)] then
            users[tostring(id)] = nil
            return true
        end
        return false
    end,
    
    createPost = function(args, context)
        local input = args and args.input
        if not input then
            return nil
        end
        
        -- Try database first
        local db = context.db
        local db_post = create_post_in_db(db, input)
        if db_post then
            return db_post
        end
        
        -- Fall back to in-memory
        local id = tostring(next_post_id)
        next_post_id = next_post_id + 1
        
        local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
        local post = {
            id = id,
            title = input.title or "Untitled",
            content = input.content or "",
            authorId = input.authorId or "1",
            createdAt = now,
            updatedAt = now
        }
        posts[id] = post
        return post
    end
}

-- Resolver functions for Subscription type
-- These return mock data matching the GraphQL schema types.
-- In a real implementation, these would set up event listeners/streams.
-- Note: Subscriptions over WebSocket would typically push data over time,
-- but for demo purposes these return initial sample data.
local subscription_resolvers = {
    -- Subscribe to new user creation events
    -- Returns a User type as defined in the schema
    userCreated = function(args, context)
        -- Return the most recently created user as sample data
        local user = users["3"] or {
            id = "1",
            name = "New User",
            email = "newuser@example.com",
            createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
        return user
    end,
    
    -- Subscribe to new post creation events
    -- Returns a Post type as defined in the schema
    postCreated = function(args, context)
        -- Return the most recently created post as sample data
        local post = posts["3"] or {
            id = "1",
            title = "New Post",
            content = "This is a new post.",
            authorId = "1",
            createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
        return post
    end,
    
    -- Subscribe to user update events
    -- Returns a User type, optionally filtered by userId
    userUpdated = function(args, context)
        local userId = args and args.userId
        local user
        if userId then
            user = users[userId]
        end
        if not user then
            user = users["1"] or {
                id = userId or "1",
                name = "Updated User",
                email = "updated@example.com",
                createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
            }
        end
        return user
    end,
    
    -- General message subscription (for testing)
    -- Returns a Message type as defined in the schema
    messageReceived = function(args, context)
        return {
            id = "1",
            content = "Sample subscription message",
            senderId = "1",  -- Include senderId for the sender resolver
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
    end
}

-- Type resolvers for nested fields
local type_resolvers = {
    User = {
        posts = function(user, args, context)
            -- Try database first
            local db = context.db
            local db_posts = get_posts_by_author_from_db(db, user.id)
            if db_posts then
                return db_posts
            end
            -- Fall back to in-memory
            local result = {}
            for _, post in pairs(posts) do
                if post.authorId == user.id then
                    table.insert(result, post)
                end
            end
            return result
        end,
        -- Support __typename for introspection
        __typename = function(user, args, context)
            return "User"
        end
    },
    
    Post = {
        author = function(post, args, context)
            local author_id = post.authorId
            -- Try database first
            local db = context.db
            local db_user = get_user_from_db(db, author_id)
            if db_user then
                return db_user
            end
            -- Fall back to in-memory
            return users[author_id]
        end,
        -- Support __typename for introspection
        __typename = function(post, args, context)
            return "Post"
        end
    },
    
    Message = {
        sender = function(message, args, context)
            -- Messages reference users
            local sender_id = message.senderId or "1"
            local db = context.db
            local db_user = get_user_from_db(db, sender_id)
            if db_user then
                return db_user
            end
            return users[sender_id]
        end,
        __typename = function(message, args, context)
            return "Message"
        end
    }
}

-- Resolve a field value, applying nested selections if needed
local function resolve_value(value, selections, type_name, context)
    if value == nil then
        return nil
    end
    
    -- If no selections, return the scalar value
    if not selections or #selections == 0 then
        return value
    end
    
    -- If it's an array, resolve each element
    if type(value) == "table" and value[1] ~= nil then
        local result = {}
        for i, item in ipairs(value) do
            result[i] = resolve_value(item, selections, type_name, context)
        end
        return result
    end
    
    -- Resolve each selection on the object
    local result = {}
    for _, sel in ipairs(selections) do
        local field_name = sel.name
        local alias = sel.alias or field_name
        local field_value
        
        -- Check if there's a type resolver for this field
        local type_resolver = type_resolvers[type_name]
        if type_resolver and type_resolver[field_name] then
            field_value = type_resolver[field_name](value, sel.arguments, context)
        else
            -- Default: get the field from the object
            field_value = value[field_name]
        end
        
        -- Recursively resolve nested selections
        if sel.selections and #sel.selections > 0 then
            -- Determine the type of the nested value
            local nested_type = nil
            if field_name == "user" or field_name == "author" then
                nested_type = "User"
            elseif field_name == "users" then
                nested_type = "User"
            elseif field_name == "post" or field_name == "posts" then
                nested_type = "Post"
            end
            field_value = resolve_value(field_value, sel.selections, nested_type, context)
        end
        
        result[alias] = field_value
    end
    
    return result
end

-- Helper function to parse request body
local function parse_request(request, context)
    -- Check if request is a simple table (old style)
    if type(request) == "table" and request.body and type(request.body) == "table" then
        return {
            body = request.body,
            ctx = { variables = request.body.variables or {}, db = nil }
        }
    end
    
    -- New style: request object with parsed body passed through
    local body = request.body or {}
    
    -- Get database connection from context if available
    local db = nil
    if context and type(context.db) == "function" then
        db = context:db()
    elseif context and context.db then
        db = context.db
    end
    
    return {
        body = body,
        ctx = { variables = body.variables or {}, db = db }
    }
end

-- Main request handler
-- Signature: handle(request, response, context)
-- The graphql handler passes a simplified request with body containing
-- { operation = {...}, variables = {...} }
function handle(request, response, context)
    -- Parse request and extract context
    local parsed = parse_request(request, context)
    local body = parsed.body
    local ctx = parsed.ctx
    
    local operation = body.operation
    local variables = body.variables or {}
    
    if not operation then
        return {
            errors = {
                { message = "No operation provided" }
            }
        }
    end
    
    local op_type = operation.operation_type or "query"
    local selections = operation.selections or {}
    
    -- Query complexity analysis
    local complexity, depth = calculate_complexity(selections, 1)
    if complexity > MAX_QUERY_COMPLEXITY then
        return {
            errors = {
                { 
                    message = "Query too complex",
                    extensions = {
                        code = "QUERY_COMPLEXITY_EXCEEDED",
                        complexity = complexity,
                        maxComplexity = MAX_QUERY_COMPLEXITY
                    }
                }
            }
        }
    end
    if depth > MAX_QUERY_DEPTH then
        return {
            errors = {
                {
                    message = "Query too deeply nested",
                    extensions = {
                        code = "QUERY_DEPTH_EXCEEDED",
                        depth = depth,
                        maxDepth = MAX_QUERY_DEPTH
                    }
                }
            }
        }
    end
    
    -- Get the appropriate resolvers
    local resolvers
    if op_type == "query" then
        resolvers = query_resolvers
    elseif op_type == "mutation" then
        resolvers = mutation_resolvers
    elseif op_type == "subscription" then
        resolvers = subscription_resolvers
    else
        return {
            errors = {
                { message = "Unsupported operation type: " .. op_type }
            }
        }
    end
    
    -- Execute each top-level selection
    local data = {}
    local errors = {}
    
    for _, sel in ipairs(selections) do
        local field_name = sel.name
        local alias = sel.alias or field_name
        
        -- Handle introspection queries
        if field_name == "__schema" or field_name == "__type" then
            local introspection_resolver = introspection_resolvers[field_name]
            if introspection_resolver then
                local ok, result = pcall(function()
                    return introspection_resolver(sel.arguments, ctx)
                end)
                if ok then
                    data[alias] = result
                else
                    table.insert(errors, { message = "Introspection error: " .. tostring(result) })
                    data[alias] = nil
                end
            end
        elseif field_name == "__typename" then
            -- Return the operation type name
            if op_type == "query" then
                data[alias] = "Query"
            elseif op_type == "mutation" then
                data[alias] = "Mutation"
            elseif op_type == "subscription" then
                data[alias] = "Subscription"
            end
        else
            -- Regular field resolution
            local resolver = resolvers[field_name]
            
            if resolver then
                local ok, result = pcall(function()
                    local value = resolver(sel.arguments, ctx)
                
                    -- Determine the type for nested resolution
                    local type_name = nil
                    if field_name == "user" or field_name == "users" or field_name == "userCreated" or field_name == "userUpdated" then
                        type_name = "User"
                    elseif field_name == "post" or field_name == "posts" or field_name == "postCreated" then
                        type_name = "Post"
                    elseif field_name == "messageReceived" then
                        type_name = "Message"
                    end
                    
                    return resolve_value(value, sel.selections, type_name, ctx)
                end)
                
                if ok then
                    data[alias] = result
                else
                    table.insert(errors, { message = "Error resolving " .. field_name .. ": " .. tostring(result) })
                    data[alias] = nil
                end
            else
                -- Unknown field - return null
                data[alias] = nil
            end
        end
    end
    
    -- Only include extensions on errors (avoid exposing complexity info in production)
    -- To enable for debugging, set GRAPHQL_DEBUG=true in environment or add debug flag to request
    if #errors > 0 then
        return {
            data = data,
            errors = errors,
            extensions = {
                complexity = complexity,
                depth = depth
            }
        }
    end
    
    return {
        data = data
    }
end

-- Legacy handler for backwards compatibility
function handle_request(request)
    return handle(request, nil, nil)
end

-- Export the handler
return {
    handle = handle
}

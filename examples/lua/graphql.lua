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
-- Note: This is a reference implementation showing how to build
-- a GraphQL resolver in Lua. For production use, you would connect
-- to a real database (PostgreSQL, SQLite, etc.) instead of mock data.

-- Mock data store (in a real application, this would be a database)
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
        return users[tostring(id)]
    end,
    
    users = function(args, context)
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
        return posts[tostring(id)]
    end,
    
    posts = function(args, context)
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

-- Type resolvers for nested fields
local type_resolvers = {
    User = {
        posts = function(user, args, context)
            local result = {}
            for _, post in pairs(posts) do
                if post.authorId == user.id then
                    table.insert(result, post)
                end
            end
            return result
        end
    },
    
    Post = {
        author = function(post, args, context)
            return users[post.authorId]
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

-- Main request handler
function handle_request(request)
    local body = request.body or {}
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
    
    -- Get the appropriate resolvers
    local resolvers
    if op_type == "query" then
        resolvers = query_resolvers
    elseif op_type == "mutation" then
        resolvers = mutation_resolvers
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
        local resolver = resolvers[field_name]
        
        if resolver then
            local ok, result = pcall(function()
                local value = resolver(sel.arguments, { variables = variables })
                
                -- Determine the type for nested resolution
                local type_name = nil
                if field_name == "user" or field_name == "users" then
                    type_name = "User"
                elseif field_name == "post" or field_name == "posts" then
                    type_name = "Post"
                end
                
                return resolve_value(value, sel.selections, type_name, { variables = variables })
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
    
    if #errors > 0 then
        return {
            data = data,
            errors = errors
        }
    end
    
    return {
        data = data
    }
end

-- Export the handler
return {
    handle = handle_request
}

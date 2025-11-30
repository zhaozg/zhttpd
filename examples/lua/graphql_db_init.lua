-- GraphQL Database Schema Initialization
-- This script creates the database tables needed for the GraphQL resolver
--
-- Usage: POST /api/graphql_db_init
--
-- This creates the users and posts tables if they don't exist,
-- and optionally seeds them with sample data.
--
-- Database Requirements:
-- Configure enable_db: true and db_uri in config.yaml

-- Initialize the GraphQL database schema
local function init_schema(db)
    if not db then
        return false, "Database not available"
    end
    
    -- Create users table
    local affected, err = db:exec([[
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT UNIQUE,
            active INTEGER DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now'))
        )
    ]])
    if err then
        return false, "Failed to create users table: " .. tostring(err)
    end
    
    -- Create posts table
    affected, err = db:exec([[
        CREATE TABLE IF NOT EXISTS posts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            content TEXT,
            author_id INTEGER NOT NULL,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (author_id) REFERENCES users(id)
        )
    ]])
    if err then
        return false, "Failed to create posts table: " .. tostring(err)
    end
    
    return true, "Schema initialized successfully"
end

-- Seed sample data
local function seed_data(db)
    if not db then
        return false, "Database not available"
    end
    
    -- Check if data already exists
    local existing = db:query("SELECT COUNT(*) as count FROM users")
    if existing and existing[1] and existing[1].count > 0 then
        return true, "Data already seeded"
    end
    
    -- Insert sample users
    local users = {
        { name = "Alice", email = "alice@example.com" },
        { name = "Bob", email = "bob@example.com" },
        { name = "Charlie", email = "charlie@example.com" }
    }
    
    for _, user in ipairs(users) do
        local affected, err = db:exec(
            "INSERT INTO users (name, email) VALUES (?, ?)",
            user.name, user.email
        )
        if err then
            return false, "Failed to insert user: " .. tostring(err)
        end
    end
    
    -- Insert sample posts
    local posts = {
        { title = "Hello World", content = "My first post!", author_id = 1 },
        { title = "GraphQL is Amazing", content = "Learn how to use GraphQL with zhttpd.", author_id = 1 },
        { title = "Zig Programming", content = "Building high-performance servers with Zig.", author_id = 2 }
    }
    
    for _, post in ipairs(posts) do
        local affected, err = db:exec(
            "INSERT INTO posts (title, content, author_id) VALUES (?, ?, ?)",
            post.title, post.content, post.author_id
        )
        if err then
            return false, "Failed to insert post: " .. tostring(err)
        end
    end
    
    return true, "Sample data seeded successfully"
end

-- Handler
function handle(request, response, context)
    local method = request:method()
    local path = request:path()
    
    -- Get database connection
    local db = context:db()
    local db_available = db ~= nil
    
    if not db_available then
        response:status(503)
        return {
            status = "error",
            message = "Database not configured. Enable it in config.yaml with enable_db: true and db_uri"
        }
    end
    
    -- GET - Check schema status
    if method == "GET" then
        local tables = db:query([[
            SELECT name FROM sqlite_master 
            WHERE type='table' AND name IN ('users', 'posts')
        ]])
        
        -- Use a single query to get both counts efficiently
        local counts = db:query([[
            SELECT 
                (SELECT COUNT(*) FROM users) as user_count,
                (SELECT COUNT(*) FROM posts) as post_count
        ]])
        
        local user_count = counts and counts[1] and counts[1].user_count or 0
        local post_count = counts and counts[1] and counts[1].post_count or 0
        
        return {
            status = "success",
            schema = {
                tables = tables,
                user_count = user_count,
                post_count = post_count
            }
        }
    end
    
    -- POST - Initialize schema and optionally seed data
    if method == "POST" then
        local body = request:body() or {}
        
        -- Initialize schema
        local success, message = init_schema(db)
        if not success then
            response:status(500)
            return { status = "error", message = message }
        end
        
        -- Seed data if requested
        local seed_message = nil
        if body.seed then
            local seed_success, seed_msg = seed_data(db)
            seed_message = seed_msg
        end
        
        return {
            status = "success",
            message = message,
            seed = seed_message
        }
    end
    
    response:status(405)
    return { status = "error", message = "Method not allowed" }
end

return {
    handle = handle
}

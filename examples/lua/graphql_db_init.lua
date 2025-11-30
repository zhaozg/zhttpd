-- GraphQL Database Schema Initialization (SQLite)
-- This script creates the database tables needed for the GraphQL resolver
--
-- Usage: POST /api/graphql_db_init
--
-- This creates the users and posts tables if they don't exist,
-- and optionally seeds them with sample data.
--
-- Database Requirements:
-- Configure enable_db: true and db_uri in config.yaml
--
-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  ⚠️  SECURITY WARNING                                                ║
-- ║                                                                      ║
-- ║  This endpoint allows schema initialization without authentication! ║
-- ║  In production environments, you MUST either:                        ║
-- ║    1. Remove this script entirely, OR                                ║
-- ║    2. Add authentication (check for admin token/session), OR         ║
-- ║    3. Disable this endpoint via config                               ║
-- ║                                                                      ║
-- ║  Example: Require admin token header for POST requests               ║
-- ╚══════════════════════════════════════════════════════════════════════╝
--
-- Note: This script uses SQLite-specific syntax.
-- For PostgreSQL, use SERIAL PRIMARY KEY and CURRENT_TIMESTAMP.
-- For MySQL, use INT AUTO_INCREMENT PRIMARY KEY and CURRENT_TIMESTAMP.

-- Initialize the GraphQL database schema (SQLite syntax)
local function init_schema(db)
    if not db then
        return false, "Database not available"
    end
    
    -- Create users table (SQLite syntax)
    local _, err = db:exec([[
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
    
    -- Create posts table (SQLite syntax)
    _, err = db:exec([[
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

-- Seed sample data with transaction support
local function seed_data(db)
    if not db then
        return false, "Database not available"
    end
    
    -- Check if data already exists
    local existing, err = db:query("SELECT COUNT(*) as count FROM users")
    if err then
        return false, "Failed to check existing data: " .. tostring(err)
    end
    if existing and existing[1] and existing[1].count > 0 then
        return true, "Data already seeded"
    end
    
    -- Start transaction for atomic seeding
    local tx_ok, tx_err = db:begin()
    if tx_err then
        return false, "Failed to start transaction: " .. tostring(tx_err)
    end
    
    -- Insert sample users
    local users = {
        { name = "Alice", email = "alice@example.com" },
        { name = "Bob", email = "bob@example.com" },
        { name = "Charlie", email = "charlie@example.com" }
    }
    
    for _, user in ipairs(users) do
        local _, insert_err = db:exec(
            "INSERT INTO users (name, email) VALUES (?, ?)",
            user.name, user.email
        )
        if insert_err then
            db:rollback()
            return false, "Failed to insert user: " .. tostring(insert_err)
        end
    end
    
    -- Insert sample posts
    local posts = {
        { title = "Hello World", content = "My first post!", author_id = 1 },
        { title = "GraphQL is Amazing", content = "Learn how to use GraphQL with zhttpd.", author_id = 1 },
        { title = "Zig Programming", content = "Building high-performance servers with Zig.", author_id = 2 }
    }
    
    for _, post in ipairs(posts) do
        local _, insert_err = db:exec(
            "INSERT INTO posts (title, content, author_id) VALUES (?, ?, ?)",
            post.title, post.content, post.author_id
        )
        if insert_err then
            db:rollback()
            return false, "Failed to insert post: " .. tostring(insert_err)
        end
    end
    
    -- Commit transaction
    local commit_ok, commit_err = db:commit()
    if commit_err then
        db:rollback()
        return false, "Failed to commit: " .. tostring(commit_err)
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
    
    -- GET - Check schema status (uses SQLite-specific sqlite_master)
    if method == "GET" then
        local tables, tables_err = db:query([[
            SELECT name FROM sqlite_master 
            WHERE type='table' AND name IN ('users', 'posts')
        ]])
        if tables_err then
            response:status(500)
            return { status = "error", message = "Failed to query tables: " .. tostring(tables_err) }
        end
        
        -- Only query counts if both tables exist
        local table_names = {}
        if tables then
            for _, t in ipairs(tables) do
                table_names[t.name] = true
            end
        end
        
        local user_count, post_count = 0, 0
        if table_names["users"] and table_names["posts"] then
            local counts, counts_err = db:query([[
                SELECT 
                    (SELECT COUNT(*) FROM users) as user_count,
                    (SELECT COUNT(*) FROM posts) as post_count
            ]])
            if counts_err then
                response:status(500)
                return { status = "error", message = "Failed to query counts: " .. tostring(counts_err) }
            end
            if counts and counts[1] then
                user_count = counts[1].user_count or 0
                post_count = counts[1].post_count or 0
            end
        end
        
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
    -- WARNING: In production, add authentication here!
    if method == "POST" then
        local body = request:body() or {}
        
        -- Initialize schema
        local success, message = init_schema(db)
        if not success then
            response:status(500)
            return { status = "error", message = message }
        end
        
        -- Seed data only if explicitly requested with boolean true
        local seed_message = nil
        if body.seed == true then
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

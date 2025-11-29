-- Example: Database-backed Authentication Script for zhttpd
-- This script demonstrates authentication with database validation
--
-- WARNING: This is a DEMO script for development/testing only!
-- Do NOT use in production without:
--   1. Cryptographically secure token generation (use /dev/urandom or OS CSPRNG)
--   2. Proper password hashing (bcrypt, argon2, etc.)
--   3. HTTPS/TLS for all communications
--   4. Rate limiting and brute-force protection
--
-- Database access is through context:db(name) where name is optional
-- (defaults to "default" data source)
--
-- The script receives authentication requests in the format:
-- {
--   "token": "the JWT or OAuth token",
--   "method": "GET|POST|PUT|DELETE|...",
--   "path": "/api/protected/resource",
--   "type": "jwt|oauth"
-- }
--
-- It should return a response indicating authentication result:
-- {
--   "authenticated": true/false,
--   "user_id": "optional user id",
--   "roles": ["optional", "roles"],
--   "error": "optional error message"
-- }
--
-- Database Requirements:
-- CREATE TABLE users (
--     id INTEGER PRIMARY KEY AUTOINCREMENT,
--     username TEXT UNIQUE NOT NULL,
--     password_hash TEXT NOT NULL,
--     roles TEXT DEFAULT 'user',
--     active INTEGER DEFAULT 1,
--     created_at INTEGER DEFAULT (strftime('%s', 'now'))
-- );
--
-- CREATE TABLE sessions (
--     token TEXT PRIMARY KEY,
--     user_id INTEGER NOT NULL,
--     expires_at INTEGER NOT NULL,
--     created_at INTEGER DEFAULT (strftime('%s', 'now')),
--     FOREIGN KEY (user_id) REFERENCES users(id)
-- );

-- In-memory session store (fallback when database is not available)
local memory_sessions = {}

-- Generate a random token
-- WARNING: This uses math.random which is NOT cryptographically secure!
-- For production use, implement secure_random_bytes() using /dev/urandom
-- or a proper cryptographic random number generator.
local function generate_token()
    -- Attempt to use /dev/urandom for better randomness (Unix systems)
    local success, f = pcall(io.open, '/dev/urandom', 'rb')
    if success and f then
        local read_success, data = pcall(f.read, f, 24)
        f:close()
        if read_success and data and #data == 24 then
            -- Convert bytes to hex string
            local hex = "session_"
            for i = 1, #data do
                hex = hex .. string.format("%02x", data:byte(i))
            end
            return hex
        end
    end
    
    -- Fallback: Use math.random (NOT secure, demo only!)
    -- Seed with time + some entropy
    math.randomseed(os.time() + os.clock() * 1000000)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local token = "session_"
    for i = 1, 32 do
        local idx = math.random(1, #chars)
        token = token .. chars:sub(idx, idx)
    end
    return token
end

-- Validate JWT token (demo format: zhttpd_<user_id>_<role>)
local function validate_jwt(db, token)
    -- Demo: Accept tokens in format "zhttpd_<user_id>_<role>"
    if token and token:match("^zhttpd_") then
        local user_id, role = token:match("^zhttpd_([^_]+)_(.+)$")
        if user_id and role then
            -- If database is available, verify user exists
            if db then
                local result = db:query(
                    "SELECT id, roles FROM users WHERE id = ? AND active = 1",
                    tonumber(user_id)
                )
                if result and #result > 0 then
                    return {
                        valid = true,
                        user_id = result[1].id,
                        roles = result[1].roles
                    }
                end
                return { valid = false, error = "User not found in database" }
            end
            -- Fallback without database
            return {
                valid = true,
                user_id = user_id,
                roles = role
            }
        end
    end
    return { valid = false, error = "Invalid token format" }
end

-- Validate session token
local function validate_session(db, token)
    if db then
        -- Check session in database
        local result = db:query(
            "SELECT s.user_id, s.expires_at, u.roles FROM sessions s " ..
            "JOIN users u ON s.user_id = u.id " ..
            "WHERE s.token = ? AND u.active = 1",
            token
        )
        if result and #result > 0 then
            local session = result[1]
            if session.expires_at > os.time() then
                return {
                    valid = true,
                    user_id = session.user_id,
                    roles = session.roles
                }
            end
            -- Session expired, clean it up
            db:exec("DELETE FROM sessions WHERE token = ?", token)
            return { valid = false, error = "Session expired" }
        end
        return { valid = false, error = "Session not found" }
    else
        -- Check in-memory session
        local session = memory_sessions[token]
        if session then
            if session.expires_at > os.time() then
                return {
                    valid = true,
                    user_id = session.user_id,
                    roles = session.roles
                }
            end
            memory_sessions[token] = nil
            return { valid = false, error = "Session expired" }
        end
        return { valid = false, error = "Session not found" }
    end
end

-- Create a new session
local function create_session(db, user_id, roles, expires_in)
    expires_in = expires_in or 3600  -- Default 1 hour
    local token = generate_token()
    local expires_at = os.time() + expires_in
    
    if db then
        local affected, err = db:exec(
            "INSERT INTO sessions (token, user_id, expires_at) VALUES (?, ?, ?)",
            token, user_id, expires_at
        )
        if err then
            return nil, "Failed to create session: " .. tostring(err)
        end
    else
        memory_sessions[token] = {
            user_id = user_id,
            roles = roles,
            expires_at = expires_at,
            created_at = os.time()
        }
    end
    
    return token, nil
end

-- Authenticate user with username/password (for login endpoint)
local function authenticate_user(db, username, password_hash)
    if db then
        local result = db:query(
            "SELECT id, username, roles FROM users " ..
            "WHERE username = ? AND password_hash = ? AND active = 1",
            username, password_hash
        )
        if result and #result > 0 then
            return result[1], nil
        end
        return nil, "Invalid credentials"
    else
        -- Demo fallback: accept any username with password "demo"
        if password_hash == "demo" then
            return {
                id = 1,
                username = username,
                roles = "user"
            }, nil
        end
        return nil, "Invalid credentials"
    end
end

-- Main authentication handler
function handle(request, response, context)
    -- Get database connection from context (nil if not configured)
    local db = context:db()  -- Gets the "default" data source
    local db_available = db ~= nil
    
    local body = request:body() or {}
    local token = body.token
    local auth_type = body.type or "jwt"
    local path = body.path or ""
    local method = body.method or "GET"
    
    -- Log authentication attempt
    print(string.format("[Auth-DB] Validating %s token for %s %s (db: %s)", 
        auth_type, method, path, db_available and "enabled" or "disabled"))
    
    if not token or token == "" then
        return {
            authenticated = false,
            error = "No token provided",
            db_enabled = db_available
        }
    end
    
    local result
    if auth_type == "jwt" then
        result = validate_jwt(db, token)
    elseif auth_type == "session" or auth_type == "oauth" then
        result = validate_session(db, token)
    else
        return {
            authenticated = false,
            error = "Unknown authentication type: " .. auth_type,
            db_enabled = db_available
        }
    end
    
    if result.valid then
        return {
            authenticated = true,
            user_id = result.user_id,
            roles = result.roles,
            message = "Authentication successful",
            db_enabled = db_available
        }
    else
        return {
            authenticated = false,
            error = result.error or "Invalid or expired token",
            db_enabled = db_available
        }
    end
end

-- Export the handler and utility functions
return {
    handle = handle,
    create_session = create_session,
    authenticate_user = authenticate_user,
    validate_jwt = validate_jwt,
    validate_session = validate_session
}

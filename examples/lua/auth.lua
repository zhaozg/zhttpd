-- Example Authentication Script for zhttpd
-- This script demonstrates the JWT/OAuth authentication interface
-- that can be used by the auth middleware.
--
-- The auth middleware calls the exported `handle_request` function with the
-- standard handler signature (request, response, context). The script reads
-- the token from the Authorization header (Bearer scheme) and returns a
-- response indicating the authentication result:
-- {
--   "authenticated": true/false,
--   "user_id": "optional user id",
--   "roles": ["optional", "roles"],
--   "error": "optional error message"
-- }
--
-- The middleware treats a response with "authenticated": true as success and
-- lets the request proceed; anything else results in a 403 response.

-- In-memory session store (for demo purposes)
-- In production, use Redis or database for session storage
local sessions = {}

-- Simple token validation
-- In production, use proper JWT library or OAuth validation
local function validate_jwt(token)
  -- Demo: Accept any non-empty token that starts with "zhttpd_"
  if token and token:match("^zhttpd_") then
    -- Extract user info from token (demo format: zhttpd_<user_id>_<role>)
    local user_id, role = token:match("^zhttpd_([^_]+)_(.+)$")
    if user_id and role then
      return {
        valid = true,
        user_id = user_id,
        roles = { role },
      }
    end
  end
  return { valid = false }
end

local function validate_oauth(token)
  -- Demo: Check if token exists in session store
  local session = sessions[token]
  if session then
    return {
      valid = true,
      user_id = session.user_id,
      roles = session.roles or {},
    }
  end
  return { valid = false }
end

-- Extract the bearer token from the Authorization header.
-- Returns nil when the header is missing or malformed.
local function extract_token(request)
  local header = request:header("authorization")
  if not header or header == "" then
    return nil
  end
  -- Accept both "Bearer <token>" and a bare token for convenience.
  local token = header:match("^[Bb]earer%s+(.+)$")
  if token then
    return token
  end
  return header
end

-- Main authentication handler invoked by the auth middleware.
-- Signature matches the standard Lua handler: (request, response, context).
function handle_request(request, response, context)
  local token = extract_token(request)
  local method = request:method()
  local path = request:path()

  -- Log authentication attempt (optional)
  print(string.format("[Auth] Validating token for %s %s", method, path))

  if not token or token == "" then
    return {
      authenticated = false,
      error = "No token provided",
    }
  end

  -- JWT-style tokens are the default; OAuth/session tokens are looked up in
  -- the in-memory session store.
  local result
  if token:match("^zhttpd_") then
    result = validate_jwt(token)
  else
    result = validate_oauth(token)
  end

  if result.valid then
    return {
      authenticated = true,
      user_id = result.user_id,
      roles = result.roles,
      message = "Authentication successful",
    }
  else
    return {
      authenticated = false,
      error = "Invalid or expired token",
    }
  end
end

-- Helper: Create a demo session (for OAuth flow)
function create_session(user_id, roles)
  local token = "session_" .. os.time() .. "_" .. math.random(10000)
  sessions[token] = {
    user_id = user_id,
    roles = roles,
    created_at = os.time(),
  }
  return token
end

-- Export the handler and utility functions
return {
  handle_request = handle_request,
  create_session = create_session,
}

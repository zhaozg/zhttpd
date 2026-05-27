-- Example Authentication Script for zhttpd
-- This script demonstrates the JWT/OAuth authentication interface
-- that can be used by the auth middleware
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

-- Main authentication handler
function handle_request(request)
  local body = request.body or {}
  local token = body.token
  local auth_type = body.type or "jwt"
  local path = body.path or ""
  local method = body.method or "GET"

  -- Log authentication attempt (optional)
  print(string.format("[Auth] Validating %s token for %s %s", auth_type, method, path))

  if not token or token == "" then
    return {
      authenticated = false,
      error = "No token provided",
    }
  end

  local result
  if auth_type == "jwt" then
    result = validate_jwt(token)
  elseif auth_type == "oauth" then
    result = validate_oauth(token)
  else
    return {
      authenticated = false,
      error = "Unknown authentication type: " .. auth_type,
    }
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

-- Export the handler
return {
  handle = handle_request,
  create_session = create_session,
}

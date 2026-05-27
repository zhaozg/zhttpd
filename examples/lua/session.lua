-- Session example script for zhttpd
-- Demonstrates session management features
--
-- Note: For complex objects (arrays, nested tables), use json.encode/decode
-- Example:
--   local json = require('json')
--   session:set("user_data", json.encode({name="John", roles={"admin"}}))
--   local user = json.decode(session:get("user_data"))

-- Helper function to get login page HTML
local function get_login_page()
  return [[
<!DOCTYPE html>
<html>
<head><title>Session Demo - Login</title></head>
<body>
    <h1>Login</h1>
    <form method="POST" action="/session">
        <label>Username: <input type="text" name="username" required></label><br><br>
        <input type="submit" value="Login">
    </form>
</body>
</html>
]]
end

-- Helper function to get session info page HTML
local function get_session_page(session, username)
  local visit_count = session:get("visit_count") or 0
  return string.format(
    [[
<!DOCTYPE html>
<html>
<head><title>Session Demo - Welcome</title></head>
<body>
    <h1>Welcome, %s!</h1>
    <p>Session ID: %s</p>
    <p>Visit count: %d</p>
    <p><a href="/session?action=logout">Logout</a></p>
    <p><a href="/session">Refresh</a></p>
</body>
</html>
]],
    username,
    session:id(),
    visit_count
  )
end

local function handle(request, response, context)
  local session = context:session()
  local method = request:method()
  local action = request:query("action")

  -- Handle logout
  if action == "logout" then
    session:destroy()
    response:status(302)
    response:header("Location", "/session")
    return { status = "redirect", message = "Logged out" }
  end

  -- Get current user from session
  local username = session:get("username")

  -- Handle POST (login)
  if method == "POST" then
    local body = request:body()
    if body and body.username then
      username = body.username
      session:set("username", username)
      session:set("visit_count", 1)
      session:set("logged_in_at", os.time())
    end
  end

  -- If logged in, show session page
  if username then
    -- Increment visit count
    local count = session:get("visit_count") or 0
    session:set("visit_count", count + 1)

    response:content_type("text/html")
    response:body(get_session_page(session, username))
    return nil
  end

  -- Show login page
  response:content_type("text/html")
  response:body(get_login_page())
  return nil
end

return { handle = handle }

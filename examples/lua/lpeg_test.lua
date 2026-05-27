-- LPeg test script for zhttpd
-- This demonstrates the basic usage of the LPeg pattern matching library

local lpeg = require("lpeg")

function handle(request, response, context)
  -- Test 1: Basic pattern matching
  local pattern = lpeg.P("hello")
  local result1 = lpeg.match(pattern, "hello world")

  -- Test 2: Range pattern (digits)
  local digit = lpeg.R("09")
  local number = digit ^ 1
  local result2 = lpeg.match(number, "12345abc")

  -- Test 3: Set pattern
  local vowel = lpeg.S("aeiouAEIOU")
  local result3 = lpeg.match(vowel ^ 1, "aeiou")

  -- Test 4: Capture pattern
  local name_pattern = lpeg.C(lpeg.R("az", "AZ") ^ 1)
  local captured_name = lpeg.match(name_pattern, "hello123")

  -- Test 5: More complex pattern - parse a simple number
  local sign = lpeg.S("+-") ^ -1
  local digits = lpeg.R("09") ^ 1
  local decimal = lpeg.P(".") * digits
  local number_full = lpeg.C(sign * digits * decimal ^ -1)
  local parsed_number = lpeg.match(number_full, "-123.456xyz")

  -- Test 6: Email validation pattern
  local letter = lpeg.R("az", "AZ")
  local digit = lpeg.R("09")
  local dot = lpeg.P(".")
  local at = lpeg.P("@")
  local username = (letter + digit + lpeg.S("_-")) ^ 1
  local domain_part = (letter + digit + lpeg.S("-")) ^ 1
  local tld = letter ^ 2 -- Top-level domain (at least 2 letters)
  local email = lpeg.C(username * at * domain_part * (dot * domain_part) ^ 0 * dot * tld)
  local email_result = lpeg.match(email, "user@example.com")

  return {
    status = "success",
    message = "LPeg module is working!",
    tests = {
      basic_match = {
        pattern = 'P("hello")',
        input = "hello world",
        result = result1,
        expected = 6, -- position after match
      },
      digits = {
        pattern = 'R("09")^1',
        input = "12345abc",
        result = result2,
        expected = 6, -- position after digits
      },
      vowels = {
        pattern = 'S("aeiouAEIOU")^1',
        input = "aeiou",
        result = result3,
        expected = 6, -- position after match
      },
      capture = {
        pattern = 'C(R("az","AZ")^1)',
        input = "hello123",
        captured = captured_name,
        expected = "hello",
      },
      number = {
        pattern = "C(sign * digits * decimal^-1)",
        input = "-123.456xyz",
        captured = parsed_number,
        expected = "-123.456",
      },
      email = {
        pattern = "username @ domain.tld",
        input = "user@example.com",
        captured = email_result,
        expected = "user@example.com",
      },
    },
    lpeg_type = type(lpeg),
    lpeg_functions = {
      P = type(lpeg.P),
      R = type(lpeg.R),
      S = type(lpeg.S),
      C = type(lpeg.C),
      match = type(lpeg.match),
    },
  }
end

return { handle = handle }

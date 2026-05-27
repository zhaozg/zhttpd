-- Advanced LPeg examples for zhttpd
-- This demonstrates more complex pattern matching scenarios

local lpeg = require('lpeg')

function handle(request, response, context)
    -- Example 1: Parse HTTP-like headers
    local function parse_headers(text)
        local name = lpeg.C((1 - lpeg.S(":\n"))^1)
        local value = lpeg.C((1 - lpeg.P("\n"))^1)
        local header = name * lpeg.P(":") * lpeg.S(" \t")^0 * value
        local headers_pattern = lpeg.Ct(lpeg.Ct(header) * (lpeg.P("\n") * lpeg.Ct(header))^0)
        return lpeg.match(headers_pattern, text)
    end

    -- Example 2: Parse CSV line
    local function parse_csv(text)
        local comma = lpeg.P(",")
        local quote = lpeg.P('"')
        local field = quote * lpeg.C((1 - quote)^0) * quote + lpeg.C((1 - comma - lpeg.P("\n"))^0)
        local record = lpeg.Ct(field * (comma * field)^0)
        return lpeg.match(record, text)
    end

    -- Example 3: URL path parameter extraction
    local function extract_path_params(pattern_path, actual_path)
        -- Convert /api/users/:id/posts/:post_id to lpeg pattern
        local segments = {}
        for segment in pattern_path:gmatch("[^/]+") do
            if segment:sub(1,1) == ":" then
                -- Named parameter
                table.insert(segments, lpeg.C((1 - lpeg.P("/"))^1))
            else
                -- Literal segment
                table.insert(segments, lpeg.P(segment))
            end
        end

        local pattern = lpeg.P("/")
        for i, seg in ipairs(segments) do
            pattern = pattern * seg
            if i < #segments then
                pattern = pattern * lpeg.P("/")
            end
        end

        return lpeg.match(pattern, actual_path)
    end

    -- Example 4: Simple expression evaluator
    local function eval_expr(expr)
        local V = lpeg.V
        local space = lpeg.S(" \t\n")^0

        local grammar = lpeg.P({
            "expr",
            expr = space * V("term") * space * ((lpeg.C(lpeg.S("+-")) * space * V("term") * space)^0),
            term = space * V("factor") * space * ((lpeg.C(lpeg.S("*/")) * space * V("factor") * space)^0),
            factor = lpeg.C(lpeg.R("09")^1) + lpeg.P("(") * V("expr") * lpeg.P(")"),
        })

        return lpeg.match(lpeg.Ct(grammar), expr)
    end

    -- Example 5: Color code parser (hex)
    local function parse_color(color_str)
        local hex_digit = lpeg.R("09", "af", "AF")
        local hex2 = lpeg.C(hex_digit * hex_digit)
        local color = lpeg.P("#") * lpeg.Ct(hex2 * hex2 * hex2)
        return lpeg.match(color, color_str)
    end

    -- Run examples
    local header_text = "Content-Type: application/json\nAuthorization: Bearer token123"
    local csv_line = 'John,Doe,"123 Main St",Springfield'
    local url_path = "/api/users/42/posts/99"
    local expression = "1 + 2 * 3"
    local color = "#ff5733"

    local headers_result = parse_headers(header_text)
    local csv_result = parse_csv(csv_line)
    local path_params = extract_path_params("/api/users/:id/posts/:post_id", url_path)
    local expr_result = eval_expr(expression)
    local color_result = parse_color(color)

    return {
        status = "success",
        message = "Advanced LPeg examples",
        examples = {
            headers = {
                input = header_text,
                parsed = headers_result,
                description = "Parse HTTP-like headers"
            },
            csv = {
                input = csv_line,
                parsed = csv_result,
                description = "Parse CSV line with quoted fields"
            },
            url_params = {
                pattern = "/api/users/:id/posts/:post_id",
                input = url_path,
                extracted = {
                    id = path_params and path_params or nil,
                    post_id = nil  -- Would need more complex pattern
                },
                description = "Extract URL path parameters"
            },
            expression = {
                input = expression,
                tokens = expr_result,
                description = "Parse arithmetic expression into tokens"
            },
            color = {
                input = color,
                rgb = color_result,
                description = "Parse hex color code into RGB components"
            }
        },
        tips = {
            "Use lpeg.Ct() to collect captures into a table",
            "Use lpeg.C() to capture matched text",
            "Patterns can be composed with *, +, and ^ operators",
            "lpeg.V() is used for recursive grammar rules",
            "Always test patterns incrementally"
        }
    }
end

return { handle = handle }

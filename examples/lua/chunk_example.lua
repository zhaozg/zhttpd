-- Chunked Response Example for zhttpd
-- This example demonstrates how to use response:chunk() for streaming responses
-- Based on http.zig streaming example: https://github.com/karlseguin/http.zig/blob/master/examples/11_html_streaming.zig

function handle(request, response, context)
    local path = request:path()
    
    if path == "/api/chunk_example/simple" then
        return handleSimpleChunk(request, response, context)
    elseif path == "/api/chunk_example/html" then
        return handleHtmlChunk(request, response, context)
    elseif path == "/api/chunk_example/sse" then
        return handleSSEChunk(request, response, context)
    else
        response:status(404)
        return { error = "Not found. Try /api/chunk_example/simple, /html, or /sse" }
    end
end

-- Simple chunked text response
function handleSimpleChunk(request, response, context)
    -- Set content type for plain text
    response:content_type("text/plain")
    
    -- Send first chunk
    response:chunk("Chunk 1: Hello from Lua!\n")
    
    -- Simulate some processing
    -- In real scenarios, you might fetch data, process streams, etc.
    response:chunk("Chunk 2: This is chunked transfer encoding.\n")
    
    -- Send more chunks
    response:chunk("Chunk 3: Each call to chunk() sends a separate chunk.\n")
    response:chunk("Chunk 4: Perfect for streaming large responses!\n")
    
    -- Return nil to prevent automatic JSON serialization
    -- When using chunk(), you typically don't want a return value
    return nil
end

-- HTML streaming with progressive rendering (like http.zig example)
function handleHtmlChunk(request, response, context)
    response:content_type("text/html")
    
    -- Send initial HTML with loading placeholders
    response:chunk([[
<!DOCTYPE html>
<html>
<head>
    <title>Chunked HTML Example</title>
    <style>
        body { font-family: sans-serif; margin: 40px; }
        .item { padding: 10px; margin: 5px 0; background: #f0f0f0; border-radius: 4px; }
        .loading { color: #999; font-style: italic; }
    </style>
</head>
<body>
    <h1>Streaming HTML Response</h1>
    <div id="items">
        <div class="item loading">Item 1: Loading...</div>
        <div class="item loading">Item 2: Loading...</div>
        <div class="item loading">Item 3: Loading...</div>
    </div>
    <script>
        let itemIndex = 0;
        function updateItem(html) {
            const items = document.querySelectorAll('.item');
            if (items[itemIndex]) {
                items[itemIndex].innerHTML = html;
                items[itemIndex].classList.remove('loading');
                itemIndex++;
            }
        }
    </script>
]])
    
    -- Simulate progressive content loading
    -- In real scenarios, these might come from database queries, API calls, etc.
    response:chunk([[
    <script>updateItem('Item 1: <strong>First item loaded!</strong>');</script>
]])
    
    response:chunk([[
    <script>updateItem('Item 2: <strong>Second item loaded!</strong>');</script>
]])
    
    response:chunk([[
    <script>updateItem('Item 3: <strong>Third item loaded!</strong>');</script>
]])
    
    -- Close HTML
    response:chunk([[
</body>
</html>
]])
    
    return nil
end

-- SSE-style chunked response (Server-Sent Events format)
function handleSSEChunk(request, response, context)
    -- Set appropriate content type for SSE
    response:content_type("text/event-stream")
    response:header("Cache-Control", "no-cache")
    response:header("Connection", "keep-alive")
    
    -- Send initial connection event
    response:chunk("event: connected\n")
    response:chunk("data: {\"status\":\"connected\",\"message\":\"Stream established\"}\n\n")
    
    -- Send some data events
    for i = 1, 3 do
        response:chunk("event: message\n")
        local data = string.format("data: {\"id\":%d,\"message\":\"Event %d\",\"timestamp\":%d}\n\n", 
            i, i, os.time())
        response:chunk(data)
    end
    
    -- Send close event
    response:chunk("event: close\n")
    response:chunk("data: {\"status\":\"complete\"}\n\n")
    
    return nil
end

return { handle = handle }

# zhttpd

[English](#english) | [中文](#中文)

---

## 中文

一个使用 Zig 语言构建的高性能、可扩展、符合 HTTP 标准的通用 Web 服务器。

### ✨ 特性

- 🚀 **高性能** - 使用 Zig 语言编写，提供原生性能
- 📁 **静态文件服务** - 支持 HTML、CSS、JavaScript、图片等各种静态资源
- ⚡ **ETag 缓存** - 支持 ETag 和条件请求，大幅减少带宽使用
- 🔧 **动态内容处理** - 通过 Lua 脚本实现灵活的动态内容和 API 处理
- 🔗 **WebSocket 支持** - 实时双向通信，支持 Lua 消息处理
- 🌊 **Chunked 响应** - Lua 支持 HTTP 分块传输编码，用于流式响应
- 🔒 **安全加固** - 默认启用 HTTP 安全头部（CSP、HSTS、X-Frame-Options 等）
- ⚙️ **灵活配置** - 支持 JSON 和 YAML 配置文件
- 🧵 **多线程支持** - 使用线程池处理并发请求
- 📝 **RESTful API** - 支持标准的 REST API 设计模式
- 📡 **Server-Sent Events** - 支持 SSE 实时数据推送
- 🛡️ **速率限制** - 令牌桶算法的请求限速中间件
- 🌐 **CORS 支持** - 可配置的跨域资源共享策略
- 🔑 **认证中间件** - JWT/OAuth 认证接口，支持 Lua 自定义验证
- 💾 **数据库插件** - 通过 zdbc 支持 SQLite、PostgreSQL、MySQL

### 🏗️ 架构设计

基于以下优秀的 Zig 生态项目：

- [http.zig](https://github.com/karlseguin/http.zig) - HTTP 协议实现
- [ziglua](https://github.com/natecraddock/ziglua) - Lua 集成
- [zdbc](https://github.com/zhaozg/zdbc) - 数据库抽象层（SQLite、PostgreSQL、MySQL）

### 📦 安装

#### 前置要求

- Zig 0.15.x 或更高版本

#### 从源码构建

```bash
git clone https://github.com/zhaozg/zhttpd.git
cd zhttpd
zig build
```

### 🚀 快速开始

#### 1. 配置服务器

复制示例配置文件并根据需要修改：

```bash
cp config.example.json config.json
```

配置文件示例（JSON）：

```json
{
  "host": "0.0.0.0",
  "port": 8080,
  "static_dir": "./examples/static",
  "lua_scripts_dir": "./examples/lua",
  "security_headers": true,
  "max_body_size": 10485760,
  "timeout_seconds": 30,
  "thread_pool_size": 4,
  "enable_lua": true
}
```

或使用 YAML 格式：

```yaml
host: "0.0.0.0"
port: 8080
static_dir: "./examples/static"
lua_scripts_dir: "./examples/lua"
security_headers: true
max_body_size: 10485760
timeout_seconds: 30
thread_pool_size: 4
enable_lua: true
```

#### 2. 启动服务器

```bash
zig build run
```

或者直接运行编译后的可执行文件：

```bash
./zig-out/bin/zhttpd
```

#### 3. 访问服务器

在浏览器中打开 http://localhost:8080

### 🖥️ 命令行参数

zhttpd 支持丰富的命令行参数，方便开发和生产环境的灵活配置：

```bash
zhttpd [选项]
```

**选项列表：**

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `-h, --help` | 显示帮助信息并退出 | - |
| `-v, --version` | 显示版本信息并退出 | - |
| `-c, --config <FILE>` | 指定配置文件路径 | zhttpd.yaml 或 config.json |
| `-p, --port <PORT>` | 设置服务器端口 | 8080 |
| `-H, --host <HOST>` | 设置绑定地址 | 0.0.0.0 |
| `-s, --static-dir <DIR>` | 设置静态文件目录 | ./examples/static |
| `-l, --lua-dir <DIR>` | 设置 Lua 脚本目录 | ./examples/lua |
| `--log-level <LEVEL>` | 设置日志级别 (debug, info, warn, error) | info |
| `-t, --threads <N>` | 设置线程池大小 | 4 |
| `--security-headers` | 启用 HTTP 安全头部 | 默认启用 |
| `--no-security-headers` | 禁用 HTTP 安全头部 | - |

**配置优先级：**

1. 命令行参数（最高优先级）
2. 指定的配置文件（`--config`）
3. 默认配置文件（zhttpd.yaml → config.json）
4. 内置默认值

**使用示例：**

```bash
# 显示帮助
zhttpd --help

# 在 3000 端口启动
zhttpd -p 3000

# 使用自定义配置文件
zhttpd -c /etc/zhttpd/config.yaml

# 仅绑定本地回环地址
zhttpd -H 127.0.0.1 -p 8000

# 开启调试日志
zhttpd --log-level debug

# 生产环境启动（8线程）
zhttpd -t 8 -p 80 -H 0.0.0.0
```

### 📖 使用指南

#### 静态文件服务

将静态文件放在配置的 `static_dir` 目录中（默认为 `./examples/static`）：

```
examples/static/
├── index.html
├── style.css
├── app.js
└── images/
    └── logo.png
```

访问方式：
- `http://localhost:8080/` → `index.html`
- `http://localhost:8080/style.css` → `style.css`
- `http://localhost:8080/images/logo.png` → `logo.png`

#### Lua 动态处理

创建 Lua 脚本在 `lua_scripts_dir` 目录中：

**examples/lua/test.lua:**

```lua
function handle_request(request)
    local response = {
        status = "success",
        message = "Hello from Lua!",
        received = request.body.message,
        timestamp = os.time()
    }
    return response
end

return {
    handle = handle_request
}
```

访问方式：
```bash
curl -X POST http://localhost:8080/api/test \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello"}'
```

#### 数据库插件

zhttpd 通过 zdbc 库提供数据库集成，支持 SQLite、PostgreSQL 和 MySQL。支持多数据源配置。

**配置数据库：**

```yaml
# 在 config.yaml 中配置
enable_db: true

# 默认数据源配置（简单模式）
db_uri: "sqlite:///data/app.db"
db_pool_size: 5

# 多数据源配置（高级模式）
# 当配置了 data_sources 时，db_uri 将被忽略
data_sources:
  - name: default
    uri: "sqlite:///data/app.db"
    pool_size: 5
  - name: users_db
    uri: "postgresql://user:password@localhost:5432/users"
    pool_size: 10
  - name: logs_db
    uri: "mysql://user:password@localhost:3306/logs"
    pool_size: 3
```

**在 Lua 中使用数据库：**

```lua
-- 数据库通过 context:db(name) 获取
function handle(request, response, context)
    -- 获取默认数据源
    local db = context:db()

    -- 或获取指定名称的数据源
    local users_db = context:db("users_db")

    if db then
        -- 执行查询
        local result, err = db:query("SELECT * FROM users WHERE id = ?", 1)
        if not err then
            for _, row in ipairs(result) do
                print(row.name)
            end
        end

        -- 执行语句
        local affected, err = db:exec(
            "INSERT INTO users (name, email) VALUES (?, ?)",
            "张三", "zhangsan@example.com"
        )

        -- 事务支持
        db:begin()
        db:exec("UPDATE accounts SET balance = balance - 100 WHERE id = ?", 1)
        db:exec("UPDATE accounts SET balance = balance + 100 WHERE id = ?", 2)
        db:commit()

        -- 获取数据库状态
        local status = db:status()
        print(status.connected)  -- true/false
    end

    return { status = "ok" }
end
```

**性能优化：**

数据库访问经过高度优化：
- `context:db()` 使用预注册的元表，避免了每次调用的开销
- 不使用数据库的 Lua 脚本零开销
- 准备语句自动缓存以提高性能
- 详见 [Lua Handler 性能优化文档](docs/LUA_HANDLER_PERFORMANCE.md)

详细示例请参阅：
- `examples/lua/users_db.lua` - 数据库用户管理 API
- `examples/lua/auth_db.lua` - 数据库认证示例
- `examples/lua/db_test.lua` - 数据库测试工具

#### WebSocket 支持

zhttpd 提供内置的 WebSocket 支持，可以通过 `/ws` 端点建立 WebSocket 连接。消息处理委托给 Lua 脚本。

**JavaScript 客户端示例：**

```javascript
const ws = new WebSocket('ws://localhost:8080/ws');

ws.onopen = () => {
    console.log('Connected to WebSocket');
    ws.send(JSON.stringify({ type: 'hello', message: 'Hello from client!' }));
};

ws.onmessage = (event) => {
    console.log('Received:', event.data);
};

ws.onclose = () => {
    console.log('Disconnected');
};
```

**Lua WebSocket 处理器：**

在 `lua_scripts_dir` 目录中创建 `websocket.lua` 文件处理 WebSocket 消息：

```lua
-- examples/lua/websocket.lua
function handle_request(request)
    local event_type = request.type  -- "connect", "message", "disconnect"
    local connection_id = request.connection_id
    local data = request.data

    if event_type == "connect" then
        return { type = "connected", message = "Welcome!" }
    elseif event_type == "message" then
        -- 处理消息并返回响应
        return { type = "message", received = data, echo = true }
    else
        return { type = "disconnected" }
    end
end

return { handle = handle_request }
```

### 🔒 安全特性

zhttpd 默认启用以下 HTTP 安全头部：

- **Content-Security-Policy** - 防止 XSS 攻击
- **X-Frame-Options** - 防止点击劫持
- **X-Content-Type-Options** - 防止 MIME 类型嗅探
- **X-XSS-Protection** - 启用浏览器 XSS 防护
- **Strict-Transport-Security (HSTS)** - 强制 HTTPS 连接
- **Referrer-Policy** - 控制 Referer 信息泄露
- **Permissions-Policy** - 控制浏览器功能访问

可以在配置文件中设置 `security_headers: false` 来禁用。

#### IP 访问控制

zhttpd 支持基于 IP 的访问控制，包括黑名单和白名单：

```yaml
enable_ip_blacklist: true
ip_blacklist: "10.0.0.0/8, 192.168.1.100"  # CIDR 和单 IP 支持
ip_whitelist: "192.168.1.1"  # 白名单 IP 跳过速率限制
```

#### HTTPS/TLS 配置

推荐使用反向代理（nginx、Caddy）进行 TLS 终止。详见 [docs/TLS_SETUP.md](docs/TLS_SETUP.md)。

#### 安全文档

- [TLS 设置指南](docs/TLS_SETUP.md) - HTTPS 配置说明
- [OWASP 合规性](docs/OWASP_COMPLIANCE.md) - 安全合规审查
- [安全功能](docs/SECURITY.md) - 安全功能详解

### 🧪 测试

运行单元测试：

```bash
zig build test
```

### 🔧 开发

#### 代码格式化

```bash
zig fmt src
```

#### 构建优化版本

```bash
zig build -Doptimize=ReleaseFast
```

#### LuaJIT 支持

zhttpd 支持两种 Lua 引擎：

- **LuaJIT**（默认）：JIT 编译，性能更优
- **Lua 5.4**：标准 Lua 解释器，稳定可靠

使用 Lua 5.4 构建（如需要）：

```bash
zig build -Dlua-lang=lua54
zig build -Dlua-lang=lua54 -Doptimize=ReleaseFast  # 生产构建
```

> ⚠️ **macOS 用户注意**：由于上游 ziglua 库的问题，LuaJIT 在 macOS 上可能会出现链接错误（"unexpected pointer encoding"）。
> 建议 macOS 用户使用 Lua 5.4 引擎：`zig build -Dlua-lang=lua54`。详见 [ziglua#issues](https://github.com/natecraddock/ziglua/issues)。

#### 内置 Lua C 模块

zhttpd 内置了两个强大的 Lua C 模块，可在所有 Lua 脚本中直接使用：

##### json 模块

高性能 json 模块（基于 [lua-cjson](https://github.com/mpx/lua-cjson)），提供 JSON 编解码功能：

```lua
-- 在 Lua 脚本中使用
local data = {name = "test", value = 123}
local json_str = json.encode(data)  -- 编码为 JSON
local parsed = json.decode(json_str)  -- 解码 JSON
```

**JSON 模块性能** (ReleaseFast, 100,000 次迭代):

| 操作 | 性能 | 说明 |
|------|------|------|
| 简单编码 | ~1,514,000 ops/s | 基础对象编码 |
| 复杂编码 | ~305,000 ops/s | 嵌套对象和数组 |
| 简单解码 | ~62,000 ops/s | 基础 JSON 字符串 |
| 复杂解码 | ~138,000 ops/s | 复杂嵌套结构 |

> 💡 zhttpd 的 json 模块集成了 lua-cjson (MIT License)，使用 `-O3` 优化编译，提供原生级别的 JSON 处理性能。

##### lpeg 模块

强大的模式匹配模块（基于 [LPeg](http://www.inf.puc-rio.br/~roberto/lpeg/)），基于解析表达式文法（PEG）提供：

```lua
-- 在 Lua 脚本中使用
local lpeg = lpeg

-- 匹配数字模式
local digit = lpeg.R("09")
local number = lpeg.C(digit^1)
local result = lpeg.match(number, "12345abc")  -- 返回 "12345"

-- 复杂模式：解析邮箱
local letter = lpeg.R("az", "AZ")
local username = (letter + digit)^1
local email = username * lpeg.P("@") * username * lpeg.P(".") * letter^2
local matched = lpeg.match(email, "user@example.com")
```

**LPeg 的优势：**
- 比正则表达式更强大，可处理嵌套结构
- 可组合的模式，易于构建复杂解析器
- 支持捕获和语法定义
- 适用于输入验证、词法分析、配置文件解析等场景

> 💡 zhttpd 的 lpeg 模块集成了 LPeg (MIT License)，提供比传统正则表达式更强大的模式匹配能力。

详细文档请参阅 [Lua C 模块集成指南](docs/LUA_C_MODULES.md)。

### 📊 性能基准

使用 Apache Bench (ab) 和 h2load 进行基准测试，构建模式：ReleaseFast

**测试环境：**
- 系统：Linux x86_64 (AMD EPYC 7763 64-Core Processor)
- CPU：2 vCPU
- 内存：8 GB
- Zig 版本：0.15.2
- HTTP 服务器：httpz (http.zig)
- 构建模式：ReleaseFast
- 线程池：2 线程

**Apache Bench 测试结果：**

| 测试场景 | 并发连接 | 总请求数 | RPS (请求/秒) | 传输速率 | 平均延迟 |
|---------|---------|---------|--------------|---------|----------|
| 低并发   | 10      | 10,000  | ~10,100      | ~42.9 MB/s | ~1.0 ms |
| 中并发   | 50      | 50,000  | ~10,600      | ~45.0 MB/s | ~4.7 ms |
| 高并发   | 100     | 100,000 | ~10,500      | ~44.5 MB/s | ~9.5 ms |

**h2load 性能测试（数据传输成功）：**

| 测试场景 | 并发连接 | 总请求数 | RPS (请求/秒) | 传输速率 | 平均延迟 |
|---------|---------|---------|--------------|---------|----------|
| 高并发   | 100     | 100,000 | ~46,000      | ~190 MB/s | ~2.1 ms |

**关键性能指标：**
- 峰值吞吐量：**~10,500 请求/秒** (Apache Bench)
- 超高吞吐量：**~46,000 请求/秒** (h2load 实际传输)
- 平均传输速率：**~45 MB/s** (Apache Bench)
- 超低延迟：< 10ms (100并发)
- 零失败请求 (Apache Bench)

**性能特点：**
- 使用 httpz.Server 提供高性能 HTTP/1.1 实现
- 优化的连接管理和并发处理
- 高效的内存分配策略（使用 arena allocator）
- ETag 支持实现智能缓存，减少带宽使用 50-90%
- 完全废弃低效的 std.http 实现

运行基准测试：

```bash
# Apache Bench
ab -n 100000 -c 100 http://127.0.0.1:8080/

# h2load
h2load --h1 -c 100 -t 4 -n 100000 http://127.0.0.1:8080/
```

### 🗺️ 项目规划

查看 [ROADMAP.md](ROADMAP.md) 了解项目的未来发展计划和增强功能。

当前版本 (v0.6.0) 已完成所有核心功能和高级中间件，处于生产就绪状态。已完成：
- ✅ 高级中间件支持 (速率限制、CORS、认证)
- ✅ SSE 实时推送
- ✅ JWT/OAuth 认证接口
- ✅ WebSocket 支持 (Lua 消息处理)
- ✅ LuaJIT/Lua 默认引擎
- ✅ 内置 json 模块
- ✅ 零拷贝缓存优化
- ✅ Lua 模块注册表缓存

未来的增强包括：
- 性能优化

详细信息请参阅 [ROADMAP.md](ROADMAP.md)。

### 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 📄 许可证

MIT License

---

## English

A high-performance, scalable, HTTP-compliant general-purpose web server built with Zig.

### ✨ Features

- 🚀 **High Performance** - Written in Zig for native performance
- 📁 **Static File Serving** - Support for HTML, CSS, JavaScript, images, and more
- ⚡ **ETag Caching** - Supports ETags and conditional requests for reduced bandwidth usage
- 🔧 **Dynamic Content** - Flexible dynamic content and API handling through Lua scripts
- 🔗 **WebSocket Support** - Real-time bidirectional communication with Lua message handling
- 🌊 **Chunked Responses** - Lua support for HTTP chunked transfer encoding for streaming responses
- 🔒 **Security Hardened** - HTTP security headers enabled by default (CSP, HSTS, X-Frame-Options, etc.)
- ⚙️ **Flexible Configuration** - Support for both JSON and YAML configuration files
- 🧵 **Multi-threading** - Thread pool for handling concurrent requests
- 📝 **RESTful API** - Support for standard REST API design patterns
- 📡 **Server-Sent Events** - SSE support for real-time data streaming
- 🛡️ **Rate Limiting** - Token bucket algorithm for request throttling
- 🌐 **CORS Support** - Configurable cross-origin resource sharing policies
- 🔑 **Authentication Middleware** - JWT/OAuth interface with Lua-based validation
- 🚫 **IP Access Control** - Blacklist/whitelist with CIDR support
- 💾 **Database Plugin** - SQLite, PostgreSQL, MySQL support via zdbc

### 🏗️ Architecture

Built on excellent Zig ecosystem projects:

- [http.zig](https://github.com/karlseguin/http.zig) - HTTP protocol implementation
- [ziglua](https://github.com/natecraddock/ziglua) - Lua integration
- [zdbc](https://github.com/zhaozg/zdbc) - Database abstraction layer (SQLite, PostgreSQL, MySQL)

### 📦 Installation

#### Prerequisites

- Zig 0.15.x or higher

#### Build from Source

```bash
git clone https://github.com/zhaozg/zhttpd.git
cd zhttpd
zig build
```

### 🚀 Quick Start

#### 1. Configure the Server

Copy the example configuration and modify as needed:

```bash
cp config.example.json config.json
```

See configuration examples in the Chinese section above.

#### 2. Start the Server

```bash
zig build run
```

Or run the compiled binary directly:

```bash
./zig-out/bin/zhttpd
```

#### 3. Access the Server

Open http://localhost:8080 in your browser

### 🖥️ Command-Line Arguments

zhttpd supports rich command-line options for flexible configuration in development and production:

```bash
zhttpd [OPTIONS]
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Print help message and exit | - |
| `-v, --version` | Print version info and exit | - |
| `-c, --config <FILE>` | Specify config file path | zhttpd.yaml or config.json |
| `-p, --port <PORT>` | Set server port | 8080 |
| `-H, --host <HOST>` | Set bind address | 0.0.0.0 |
| `-s, --static-dir <DIR>` | Set static files directory | ./examples/static |
| `-l, --lua-dir <DIR>` | Set Lua scripts directory | ./examples/lua |
| `--log-level <LEVEL>` | Set log level (debug, info, warn, error) | info |
| `-t, --threads <N>` | Set thread pool size | 4 |
| `--security-headers` | Enable HTTP security headers | enabled by default |
| `--no-security-headers` | Disable HTTP security headers | - |

**Configuration Priority:**

1. Command-line arguments (highest priority)
2. Specified config file (`--config`)
3. Default config files (zhttpd.yaml → config.json)
4. Built-in defaults

**Examples:**

```bash
# Show help
zhttpd --help

# Start on port 3000
zhttpd -p 3000

# Use custom config file
zhttpd -c /etc/zhttpd/config.yaml

# Bind to localhost only
zhttpd -H 127.0.0.1 -p 8000

# Enable debug logging
zhttpd --log-level debug

# Production startup (8 threads)
zhttpd -t 8 -p 80 -H 0.0.0.0
```

### 📖 Usage Guide

See the detailed usage guide in the Chinese section above.

### 🧪 Testing

Run unit tests:

```bash
zig build test
```

### 📊 Performance Benchmarks

Benchmarked with Apache Bench (ab) and h2load, Build Mode: ReleaseFast

**Test Environment:**
- System: Linux x86_64 (AMD EPYC 7763 64-Core Processor)
- CPU: 2 vCPU
- Memory: 8 GB
- Zig Version: 0.15.2
- HTTP Server: httpz (http.zig)
- Build Mode: ReleaseFast
- Thread Pool: 2 threads

**Apache Bench Results:**

| Test Scenario | Concurrency | Total Requests | RPS     | Transfer Rate | Avg Latency |
|--------------|-------------|----------------|---------|---------------|-------------|
| Low          | 10          | 10,000         | ~10,100 | ~42.9 MB/s    | ~1.0 ms     |
| Medium       | 50          | 50,000         | ~10,600 | ~45.0 MB/s    | ~4.7 ms     |
| High         | 100         | 100,000        | ~10,500 | ~44.5 MB/s    | ~9.5 ms     |

**h2load Performance (actual data transfer successful):**

| Test Scenario | Concurrency | Total Requests | RPS     | Transfer Rate | Avg Latency |
|--------------|-------------|----------------|---------|---------------|-------------|
| High         | 100         | 100,000        | ~46,000 | ~190 MB/s     | ~2.1 ms     |

**Key Metrics:**
- Peak Throughput: **~10,500 req/s** (Apache Bench)
- Ultra-high Throughput: **~46,000 req/s** (h2load actual transfer)
- Average Transfer Rate: **~45 MB/s** (Apache Bench)
- Ultra-low Latency: < 10ms (100 concurrent)
- Zero Failed Requests (Apache Bench)

**Performance Features:**
- Using httpz.Server for high-performance HTTP/1.1 implementation
- Optimized connection management and concurrency handling
- Efficient memory allocation strategy (arena allocator)
- ETag support for intelligent caching, reducing bandwidth usage by 50-90%
- Completely deprecated inefficient std.http implementation

Run benchmarks:

```bash
# Apache Bench
ab -n 100000 -c 100 http://127.0.0.1:8080/

# h2load
h2load --h1 -c 100 -t 4 -n 100000 http://127.0.0.1:8080/
```

### 🗺️ Roadmap

See [ROADMAP.md](ROADMAP.md) for the project's future development plans and enhancement opportunities.

Current version (v0.6.0) has completed all core features and advanced middleware, and is production-ready. Completed:
- ✅ Advanced middleware support (Rate limiting, CORS, Authentication)
- ✅ SSE real-time streaming
- ✅ JWT/OAuth authentication interface
- ✅ WebSocket support with Lua message handling
- ✅ LuaJIT as default engine (better performance)
- ✅ Built-in json module
- ✅ Zerocopy cache optimization
- ✅ Lua module registry caching

Future enhancements include:
- Performance optimizations

For details, see [ROADMAP.md](ROADMAP.md).

### 🔧 Development

#### Format Code

```bash
zig fmt src
```

#### Build Optimized Version

```bash
zig build -Doptimize=ReleaseFast
```

#### LuaJIT Support

zhttpd supports two Lua engines:

- **LuaJIT** (default): JIT compilation for better performance
- **Lua 5.4**: Standard Lua interpreter, stable and well-tested

Build with Lua 5.4 (if needed):

```bash
zig build -Dlua-lang=lua54
zig build -Dlua-lang=lua54 -Doptimize=ReleaseFast  # Production build
```

> ⚠️ **macOS Users Note**: Due to an upstream issue in the ziglua library, LuaJIT may fail to link on macOS with an "unexpected pointer encoding" error.
> macOS users are recommended to use Lua 5.4 engine: `zig build -Dlua-lang=lua54`. See [ziglua#issues](https://github.com/natecraddock/ziglua/issues) for updates.

#### Built-in Lua C Modules

zhttpd includes two powerful built-in Lua C modules available in all Lua scripts:

##### json Module

High-performance json module (based on [lua-cjson](https://github.com/mpx/lua-cjson)) for JSON encoding/decoding:

```lua
-- In Lua scripts
local data = {name = "test", value = 123}
local json_str = json.encode(data)  -- Encode to JSON
local parsed = json.decode(json_str)  -- Decode JSON
```

**JSON Module Performance** (ReleaseFast, 100,000 iterations):

| Operation | Performance | Notes |
|-----------|-------------|-------|
| Simple Encode | ~1,514,000 ops/s | Basic object encoding |
| Complex Encode | ~305,000 ops/s | Nested objects and arrays |
| Simple Decode | ~62,000 ops/s | Basic JSON strings |
| Complex Decode | ~138,000 ops/s | Complex nested structures |

> 💡 zhttpd's json module integrates lua-cjson (MIT License), compiled with `-O3` optimization for native-level JSON processing performance.

##### lpeg Module

Powerful pattern matching module (based on [LPeg](http://www.inf.puc-rio.br/~roberto/lpeg/)) using Parsing Expression Grammars (PEGs):

```lua
-- In Lua scripts
local lpeg = lpeg

-- Match number patterns
local digit = lpeg.R("09")
local number = lpeg.C(digit^1)
local result = lpeg.match(number, "12345abc")  -- Returns "12345"

-- Complex pattern: Email parsing
local letter = lpeg.R("az", "AZ")
local username = (letter + digit)^1
local email = username * lpeg.P("@") * username * lpeg.P(".") * letter^2
local matched = lpeg.match(email, "user@example.com")
```

**LPeg Advantages:**
- More powerful than regular expressions, handles nested structures
- Composable patterns for building complex parsers
- Support for captures and grammar definitions
- Ideal for input validation, lexical analysis, and config parsing

> 💡 zhttpd's lpeg module integrates LPeg (MIT License), providing pattern matching capabilities beyond traditional regex.

See [Lua C Module Integration Guide](docs/LUA_C_MODULES.md) for details.

### 🤝 Contributing

Issues and Pull Requests are welcome!

### 📄 License

MIT License

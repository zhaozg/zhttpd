# zhttpd

[English](#english) | [中文](#中文)

---

## 中文

一个使用 Zig 语言构建的高性能、可扩展、符合 HTTP 标准的通用 Web 服务器。

### ✨ 特性

- 🚀 **高性能** - 使用 Zig 语言编写，提供原生性能
- 📁 **静态文件服务** - 支持 HTML、CSS、JavaScript、图片等各种静态资源
- 🔧 **动态内容处理** - 通过 Lua 脚本实现灵活的动态内容和 API 处理
- 🔍 **GraphQL API** - 内置 GraphQL 支持，提供强大的 API 查询能力
- 🔒 **安全加固** - 默认启用 HTTP 安全头部（CSP、HSTS、X-Frame-Options 等）
- ⚙️ **灵活配置** - 支持 JSON 和 YAML 配置文件
- 🧵 **多线程支持** - 使用线程池处理并发请求
- 📝 **RESTful API** - 支持标准的 REST API 设计模式

### 🏗️ 架构设计

基于以下优秀的 Zig 生态项目：

- [http.zig](https://github.com/karlseguin/http.zig) - HTTP 协议实现
- [ziglua](https://github.com/natecraddock/ziglua) - Lua 集成
- [grapzig](https://github.com/yousif-wali/grapzig) - GraphQL 实现

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
  "enable_lua": true,
  "enable_graphql": true,
  "graphql_endpoint": "/graphql"
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
enable_graphql: true
graphql_endpoint: "/graphql"
```

#### 2. 启动服务器

```bash
zig build run
```

#### 3. 访问服务器

在浏览器中打开 http://localhost:8080

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

#### GraphQL API

GraphQL 端点默认为 `/graphql`。

**查询示例：**

```graphql
query {
  users {
    id
    name
    email
  }
}
```

**使用 curl：**

```bash
curl -X POST http://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ users { id name email } }"}'
```

**Mutation 示例：**

```graphql
mutation {
  createUser(input: {
    name: "张三"
    email: "zhangsan@example.com"
  }) {
    id
    name
    email
  }
}
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

### 📊 性能基准

使用 Apache Bench (ab) 进行基准测试，构建模式：ReleaseFast

**测试环境：**
- 系统：Linux x86_64
- Zig 版本：0.15.2
- HTTP 服务器：httpz (http.zig)
- 构建模式：ReleaseFast

**测试结果：**

| 测试场景 | 并发连接 | 总请求数 | RPS (请求/秒) | 传输速率 | 平均延迟 |
|---------|---------|---------|--------------|---------|----------|
| 低并发   | 10      | 10,000  | 10,049       | 40.3 MB/s | 0.995 ms |
| 中并发   | 50      | 50,000  | 10,246       | 41.0 MB/s | 4.880 ms |
| 高并发   | 100     | 100,000 | 10,196       | 40.8 MB/s | 9.807 ms |

**关键性能指标：**
- 峰值吞吐量：**~10,000 请求/秒** (提升 43% 相比之前的实现)
- 平均传输速率：**~41 MB/s** (提升 46%)
- 超低延迟：< 10ms (100并发)
- 零失败请求

**性能提升原因：**
- 使用 httpz.Server 替代自定义 HTTP 实现
- 更好的连接管理和并发处理
- 优化的内存分配策略

运行基准测试：

```bash
./scripts/benchmark.sh
```

**关于 h2load 测试：**
由于 httpz 库与 h2load 工具的兼容性问题，h2load --h1 测试无法正确识别响应状态码。
这是已知问题，不影响实际功能。详见 [docs/h2load_compatibility.md](docs/h2load_compatibility.md)
Apache Bench 测试结果准确可靠。

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
- 🔧 **Dynamic Content** - Flexible dynamic content and API handling through Lua scripts
- 🔍 **GraphQL API** - Built-in GraphQL support for powerful API querying
- 🔒 **Security Hardened** - HTTP security headers enabled by default (CSP, HSTS, X-Frame-Options, etc.)
- ⚙️ **Flexible Configuration** - Support for both JSON and YAML configuration files
- 🧵 **Multi-threading** - Thread pool for handling concurrent requests
- 📝 **RESTful API** - Support for standard REST API design patterns

### 🏗️ Architecture

Built on excellent Zig ecosystem projects:

- [http.zig](https://github.com/karlseguin/http.zig) - HTTP protocol implementation
- [ziglua](https://github.com/natecraddock/ziglua) - Lua integration
- [grapzig](https://github.com/yousif-wali/grapzig) - GraphQL implementation

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

#### 3. Access the Server

Open http://localhost:8080 in your browser

### 📖 Usage Guide

See the detailed usage guide in the Chinese section above.

### 🧪 Testing

Run unit tests:

```bash
zig build test
```

### 📊 Performance Benchmarks

Benchmarked with Apache Bench (ab), Build Mode: ReleaseFast

**Test Environment:**
- System: Linux x86_64
- Zig Version: 0.15.2
- HTTP Server: httpz (http.zig)
- Build Mode: ReleaseFast

**Results:**

| Test Scenario | Concurrency | Total Requests | RPS     | Transfer Rate | Avg Latency |
|--------------|-------------|----------------|---------|---------------|-------------|
| Low          | 10          | 10,000         | 10,049  | 40.3 MB/s     | 0.995 ms    |
| Medium       | 50          | 50,000         | 10,246  | 41.0 MB/s     | 4.880 ms    |
| High         | 100         | 100,000        | 10,196  | 40.8 MB/s     | 9.807 ms    |

**Key Metrics:**
- Peak Throughput: **~10,000 req/s** (43% improvement over previous implementation)
- Average Transfer Rate: **~41 MB/s** (46% improvement)
- Ultra-low Latency: < 10ms (100 concurrent)
- Zero Failed Requests

**Performance Improvements:**
- Using httpz.Server instead of custom HTTP implementation
- Better connection management and concurrency handling
- Optimized memory allocation strategy

Run benchmarks:

```bash
./scripts/benchmark.sh
```

**Note on h2load Testing:**
Due to compatibility issues between httpz library and h2load tool, h2load --h1 tests 
cannot correctly recognize response status codes. This is a known issue and doesn't 
affect actual functionality. See [docs/h2load_compatibility.md](docs/h2load_compatibility.md) 
for details. Apache Bench results are accurate and reliable.

### 🔧 Development

#### Format Code

```bash
zig fmt src
```

#### Build Optimized Version

```bash
zig build -Doptimize=ReleaseFast
```

### 🤝 Contributing

Issues and Pull Requests are welcome!

### 📄 License

MIT License

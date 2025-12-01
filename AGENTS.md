# AGENT.md

本项目目标为实现一个高性能、可扩展、符合 HTTP 标准的通用Web服务器

## 功能

- 支持静态页面
- 支持 Lua 动态页面生成
- 支持 Restful API 服务
- 支持 配置文件(JSON 或 YAML) 进行服务器参数配置

## 要求

1. 基于 [http.zig](https://github.com/karlseguin/http.zig) 实现通用 HTTP Web服务器
2. 基于 [ziglua](https://github.com/natecraddock/ziglua) 实现 Lua 集成, 实现 Lua 动态页面生成能力
3. 基于 [grapzig](https://github.com/yousif-wali/grapzig)，集成 GraphQL API 能力, 支持 Lua 动态生成响应
4. 注意 HTTP 协议的安全性处理，默认加载HTTP头部的安全参数
5. 基于 h2load 进行长连接的性能基准测试，将性能测试数据更新到 README.md
6. 单个代码文件不超过 500 行，必要时进行模块拆分

## Build/Lint/Test Commands

- `zig build` - Compile zig source code to zig-out/bin/
- `zig build test` - Run All units test
- `zig fmt --check src` - Run code style check

## requirements

- Must build and test pass with zig 0.15.x, download URL in https://ziglang.org/download/index.json
- All CI must pass.
- Update benchmark results with ReleaseFast mode in README.md if applicable.
- Push PR after `zig fmt src`

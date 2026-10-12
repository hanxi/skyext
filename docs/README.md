# skyext

> 基于 [skynet](https://github.com/cloudwu/skynet) 的分布式游戏服务器框架

## 特性

- **引擎/游戏分层** — 引擎层通用基础设施，游戏层专注业务逻辑
- **分布式架构** — account / role 节点分离部署，基于 etcd 的服务发现
- **ORM 框架** — schema 定义、数据版本管理、MongoDB 持久化
- **通用实体系统** — 支持任意实体类型（role、guild 等），自动路由、可靠消息、模块化
- **测试框架** — 内置 skytest，`.test.lua` 紧跟源码，每文件独立进程，C 加速覆盖率
- **统一 CLI** — Unix/macOS 使用 `./bin/skyext <command>`，Windows 使用 `bin\skyext.bat <command>`；两种包装入口共用纯 Lua 实现
- **热更新** — 代码热更新、配置热加载、GM 命令系统

## 快速开始

```bash
# 克隆 & 初始化
git clone https://github.com/hanxi/skyext.git
cd skyext && make init

# 编译
cd example && make build && cd ..

# 启动服务
./bin/skyext serve account1
./bin/skyext serve role1

# 运行测试
./bin/skyext test
./bin/skyext test --cov
```

Windows CMD/PowerShell 中，从仓库根目录使用 `bin\skyext.bat test` 等对应命令（需要先构建 `bin\lua.exe`）。

代码生成使用 `./bin/skyext generate proto` 或 `./bin/skyext generate schema`。打包分两类：`./bin/skyext package game` 生成示例游戏部署包（等同于 `make dist`）；`./bin/skyext package framework <platform>` 生成供 GitHub Actions 发布的框架平台包。

## 文档导航

| 章节 | 说明 |
|------|------|
| [项目概述](overview.md) | 项目背景、架构总览、开发路线图 |
| [快速上手](getting-started.md) | 环境搭建、编译运行 |
| [登录流程](guide/login.md) | 客户端登录认证全流程 |
| [登录流程图](guide/login_diagram.md) | Mermaid 可视化流程图与时序图 |
| [热更新操作](guide/hotfix.md) | 热更新类型、配置、操作 SOP |
| [GM 命令接口](guide/gm_api.md) | GM 系统 HTTP API 文档 |
| [实体系统设计](design/entity_system.md) | 通用实体系统设计方案 |
| [测试框架设计](design/skytest.md) | skytest 框架与覆盖率设计 |
| [性能分析器](design/profiler.md) | 火焰图分析器设计（待实现） |
| [管理后台规划](plan/admin_panel.md) | 管理后台功能规划 |

## 链接

- [GitHub 仓库](https://github.com/hanxi/skyext)
- [覆盖率报告](https://hanxi.github.io/skyext/coverage/)
- [Demo 客户端](https://github.com/hanxi/phaser-game)

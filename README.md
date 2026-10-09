# 游戏服务器 skyext

🎮 [WIP] [skyext](https://github.com/hanxi/skyext) 是一个基于 [skynet](https://github.com/cloudwu/skynet) 实现的分布式游戏服务器框架

🚀 欢迎 Star & Fork！

目前还处于早期开发中，仅用于学习参考！

## ✨ 特性

- **分布式架构**: 基于 skynet 实现的高性能分布式游戏服务器
- **引擎/游戏分层**: 引擎层（`lualib/skyext/`、`service/`）与游戏层（`example/`）清晰分离
- **微服务设计**: 支持 account 节点和 role 节点分离部署
- **ORM 支持**: 内置 ORM 框架，支持 MongoDB 数据持久化
- **协议管理**: 使用 sproto 协议，支持协议版本校验
- **服务发现**: 基于 etcd 的服务注册与发现
- **JWT 认证**: 支持 JWT token 登录验证（基于 OpenSSL HMAC）
- **日志系统**: 完善的日志记录和管理系统
- **TLS 支持**: skynet 编译时启用 TLS 模块（ltls）
- [ ] **热更新**: 支持代码热更新和配置热加载
- [ ] **监控系统**: 完善监控告警系统
- [ ] **管理后台**: 完善管理后台，包括火焰图分析

## 🏗️ 架构设计

### 引擎层与游戏层

skyext 采用引擎/游戏两层架构：

- **引擎层**（skyext 仓库根目录）：提供通用的游戏服务器基础设施
  - `lualib/skyext/` — 引擎 Lua 库，统一使用 `skyext.*` 命名空间
  - `service/` — 引擎服务（GM、热更、日志、集群发现、MongoDB 等）
  - `public/` — 引擎静态资源（GM 管理面板等）
- **游戏层**（`example/` 目录）：基于引擎开发的具体游戏逻辑
  - `example/nodes/` — 各节点入口（account、role、robot）
  - `example/lualib/` — 游戏业务 Lua 库
  - `example/etc/` — 游戏配置文件

### 节点类型

- **Account 节点**: 负责用户账号管理、登录验证、角色创建等
- **Role 节点**: 负责角色数据管理、游戏逻辑处理
- **Robot 节点**: 机器人客户端，用于压力测试

### 核心模块

- **ORM 系统**: `lualib/orm/` — 对象关系映射，支持数据版本管理
- **服务发现**: `lualib/skyext/cluster_discovery.lua` — 基于 etcd 的集群发现
- **数据库管理**: `lualib/skyext/dbmgr.lua` — MongoDB 连接池管理
- **协议处理**: `lualib/skyext/sproto_api.lua` — sproto 协议编解码
- **HTTP 服务**: `lualib/skyext/http_server/` — HTTP 服务器实现
- **分布式锁**: `lualib/skyext/distributed_lock.lua` — 基于 etcd 的分布式锁
- **配置管理**: `lualib/skyext/config.lua` — 统一配置读取接口
- **GM 系统**: `lualib/skyext/gm_api.lua` + `lualib/skyext/gm_router.lua` — GM 命令注册与 HTTP 路由
- **日志系统**: `lualib/skyext/log/` — 结构化日志（控制台、文件、服务间通信）

## 📋 依赖环境

- **skynet**: 游戏服务器框架（含 TLS 支持）
- **etcd**: 服务发现和配置管理
- **MongoDB**: 数据持久化存储
- **OpenSSL**: 加密库（HMAC-SHA256/SHA512、base64url）
- **lua-cjson**: JSON 处理
- **sproto**: 协议序列化

## 🚀 快速开始

### 1. 初始化项目

```bash
# 克隆项目
git clone https://github.com/hanxi/skyext.git
cd skyext

# 初始化子模块
make init

# 编译项目（在 example/ 目录下）
cd example
make build
```

### 2. 启动基础服务

启动 etcd 集群：

```bash
cd example/tools/etcd
docker compose up -d
```

启动 MongoDB：

```bash
cd example/tools/mongodb
docker compose up -d
```

### 3. 生成协议和模式文件

```bash
cd example

# 生成协议文件
make proto

# 生成 ORM 模式文件
make schema
```

### 4. 启动游戏服务器

```bash
# 在 skyext 根目录下启动（root="./" 指向根目录）

# 启动 account 节点（支持多实例）
./bin/skynet example/etc/account1.conf.lua
./bin/skynet example/etc/account2.conf.lua

# 启动 role 节点（支持多实例）
./bin/skynet example/etc/role1.conf.lua
./bin/skynet example/etc/role2.conf.lua
```

### 5. 启动机器人测试

```bash
# 启动机器人客户端进行测试
./bin/skynet example/etc/robot.conf.lua
```

## 📁 目录结构

```
skyext/
├── lualib/                # 引擎 Lua 库
│   ├── skyext/            # 引擎模块（require "skyext.*"）
│   │   ├── init.lua       # 引擎引导模块
│   │   ├── config.lua     # 配置管理
│   │   ├── log/           # 日志系统
│   │   ├── http_server/   # HTTP 服务器
│   │   ├── entity/        # 实体系统
│   │   ├── gm_api.lua     # GM 命令注册
│   │   ├── gm_router.lua  # GM HTTP 路由
│   │   ├── dbmgr.lua      # 数据库管理
│   │   ├── etcd.lua       # etcd 客户端
│   │   └── util/          # 工具库
│   ├── orm/               # ORM 框架
│   └── loader.lua         # 服务加载器
├── service/               # 引擎服务
│   ├── gm.lua             # GM 调度服务
│   ├── gm_sys.lua         # GM 系统命令
│   ├── hotfix.lua         # 热更新服务
│   ├── cluster_discovery.lua  # 集群发现
│   ├── mongo_conn.lua     # MongoDB 连接
│   ├── entity_agent.lua   # 实体代理
│   └── logger/            # 日志服务
├── public/                # 引擎静态资源
│   └── gm.html            # GM Web 管理面板
├── lualib-src/            # 引擎 C 模块源码
│   └── crypto.c           # 加密模块（OpenSSL）
├── service-src/           # 引擎 C 服务源码
├── example/               # 示例游戏项目
│   ├── nodes/             # 节点入口
│   │   ├── account/       # 账号服务
│   │   ├── role/          # 角色服务
│   │   └── robot/         # 机器人客户端
│   ├── etc/               # 游戏配置文件
│   │   ├── core.conf.lua  # 核心配置（含搜索路径）
│   │   ├── paths.conf.lua # Lua 搜索路径定义
│   │   ├── nodes/         # 节点业务配置
│   │   ├── account*.conf.lua
│   │   └── role*.conf.lua
│   ├── lualib/            # 游戏业务 Lua 库
│   ├── proto/             # 协议定义文件
│   ├── schema/            # 数据模式定义
│   ├── hotfix/            # 热更包
│   ├── res/               # 游戏资源（策划配表等）
│   ├── test/              # 测试用例
│   ├── tools/             # 工具脚本
│   └── Makefile           # 游戏构建入口
├── build.mk               # 引擎构建规则
├── Makefile               # 顶层 Makefile
├── skynet/                # skynet 框架（子模块）
├── 3rd/                   # 第三方库（子模块）
│   ├── sproto-orm/
│   ├── lua-cjson/
│   ├── binaryheap.lua/
│   └── luafilesystem/
├── docs/                  # 文档
└── tools/                 # 引擎工具
```

## ⚙️ 配置说明

### 配置文件结构

项目采用分层配置设计，配置文件分为两个层级：

1. **节点配置文件**：位于 `example/etc/` 目录下，定义节点启动参数
   - `example/etc/account*.conf.lua`: Account 节点配置文件
   - `example/etc/role*.conf.lua`: Role 节点配置文件
   - `example/etc/core.conf.lua`: 核心配置文件，包含 skynet 框架基础配置和搜索路径

2. **应用配置文件**：位于 `example/etc/nodes/` 目录下，定义具体业务配置
   - `example/etc/nodes/common.app.lua`: 通用业务配置（日志、数据库、etcd 等）
   - `example/etc/nodes/account*.app.lua`: Account 节点业务配置
   - `example/etc/nodes/role*.app.lua`: Role 节点业务配置
   - `example/etc/nodes/robot.app.lua`: 机器人客户端业务配置

### 节点配置文件

节点配置文件是 skynet 启动时加载的配置，主要定义：

- 启动脚本路径
- Lua 搜索路径
- 线程数等基础参数
- 应用配置文件路径

示例 (`example/etc/account1.conf.lua`)：
```lua
app_config_path = "etc/nodes/account1.app.lua"
start = "account" -- 主脚本 account/main.lua
include "core.conf.lua" -- 包含核心配置
```

### 应用配置文件

应用配置文件定义具体的业务参数，支持以下数据类型：
- string: 字符串类型
- number: 数值类型
- boolean: 布尔类型
- table: 表类型（复杂配置结构）

示例 (`example/etc/nodes/common.app.lua`)：
```lua
-- 日志配置
log_level = 4 -- 日志等级 DEBUG = 4, INFO = 3, WARN = 2, ERROR = 1, FATAL = 0

-- 数据库配置
mongo_config = {
    center = {
        connections = 4, -- 连接数
        cfg = {
            host = "127.0.0.1",
            port = 27017,
        },
    },
}

-- 其他配置
max_role_count = 5 -- 最大角色数量
```

### config 配置模块

配置模块 (`lualib/skyext/config.lua`) 提供统一的配置读取接口：
- `config.get(key)`: 获取字符串类型配置
- `config.get_boolean(key)`: 获取布尔类型配置
- `config.get_number(key)`: 获取数值类型配置
- `config.get_table(key)`: 获取表类型配置

配置语法遵循 [skynet 官方文档 Config](https://github.com/cloudwu/skynet/wiki/Config) 规范。应用配置文件支持 table 类型配置，支持嵌套结构。

## 🔧 开发工具

```bash
cd example

# 清理编译文件
make clean

# 打包发布
make dist

# 格式化代码
make format

# 代码检查
make lint

# 查看所有可用命令
make help
```

## 🎮 游戏功能

### 已实现功能

- **用户系统**: 账号注册、登录、JWT 认证
- **角色系统**: 角色创建、数据持久化、模块化设计
- **服务发现**: 动态服务注册与发现

### 扩展模块

项目采用模块化设计，可以轻松扩展新功能：

- 在 `example/schema/` 目录定义数据结构
- 在 `example/proto/roleagent/` 目录定义协议
- 使用 `make autocode` 自动生成模块代码

### 计划实现功能

- **策划配置**: 策划 excel 配置管理
- **背包系统**: 物品管理
- **邮件系统**: 邮件收发功能
- **社交系统**: 好友系统、群聊系统
- **游戏内商城**: 商品管理、交易功能
- **交易系统**: 物品交易拍卖功能
- **副本系统**: 副本创建、副本内玩法
- **排行榜系统**: 玩家排行榜
- **活动系统**: 活动管理、活动玩法

## 🔗 相关工程

- **Demo 客户端**: [phaser-game](https://github.com/hanxi/phaser-game) - 基于 Phaser 的游戏客户端
- **网关服务**: [goscon](https://github.com/hanxi/goscon) - WebSocket 转 TCP 网关
- **登录鉴权**: [gamepass](https://github.com/hanxi/gamepass) - 第三方登录鉴权服务

## 📚 文档

- [GM 命令接口](docs/gm_api.md) - GM 系统 HTTP API 文档
- [热更新系统](docs/hotfix.md) - 热更新操作与开发指南
- [项目 Wiki](https://github.com/hanxi/skyext/wiki) - 详细开发文档
- [Skynet 官方文档](https://github.com/cloudwu/skynet/wiki) - Skynet 框架文档

## 💬 交流讨论

- **QQ 群**: `677839887`
- **GitHub Issues**: 提交 Bug 报告和功能建议

## 📄 许可证

本项目基于 MIT 许可证开源，详见 [LICENSE](LICENSE) 文件。

## 🤝 贡献

欢迎提交 Pull Request 和 Issue！

1. Fork 本项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

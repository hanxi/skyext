# Generic Entity System + Router 设计方案

## Context

当前 `roleagent` 系统与 "role" 实体强耦合。如果要支持公会(guild)、场景(scene)、怪物(monster)等其他实体，需要为每种实体复制一整套 agent/agentmgr/api 代码。本方案设计一套通用的 Entity 系统，使得任何实体类型只需定义配置和 handler 即可复用完整的生命周期管理、消息路由和持久化能力。

**核心需求：**
- Entity ID 稳定不变（snowflake ID，已有）
- 节点重启路由不变（jchash + 固定节点列表）
- 支持 `call`、`send`、`reliable_send`（持久化消息，保证送达）

---

## 架构总览

```
任意 Service                    entity_agent:guild:1 (skynet service)
     |                                  |
     | router.call("guild", gid, cmd)   |
     |--------------------------------->| entity_call(gid, cmd, ...)
     |                                  |   -> entitymgr.ensure_loaded(gid)
     |  (local: skynet.call)            |   -> handler[cmd](entity, ...)
     |  (remote: cluster.call)          |
     |<---------------------------------| return result
```

**关键组件：**

| 文件 | 职责 |
|------|------|
| `lualib/skyext/entity/types.lua` | 实体类型注册表，路由计算（jchash 选节点，modulo 选 agent） |
| `lualib/skyext/entity/router.lua` | 公共 API：call / send / reliable_send，自动路由到正确节点 |
| `lualib/skyext/entity/entitymgr.lua` | 单 agent 内实体生命周期（加载/卸载/缓存），复用 `dbmgr` + `distributed_lock` |
| `lualib/skyext/entity/reliable_msg.lua` | 可靠消息持久化（MongoDB），加载时投递 pending 消息 |
| `service/entity_agent.lua` | 通用实体 agent 服务，按 type 参数化 |
| `service/entity_agentmgr.lua` | agent 管理器 |

---

## 复用的现有组件

| 组件 | 路径 | 用途 |
|------|------|------|
| jchash | `lualib-src/jchash.c` | 已编译，`jchash.hash(key, buckets)` → 稳定路由 |
| distributed_lock | `lualib/skyext/distributed_lock.lua` | etcd 分布式锁，确保实体全局唯一加载 |
| dbmgr | `lualib/skyext/dbmgr.lua` | MongoDB ORM 加载/存盘/卸载，含脏数据定时刷盘 |
| cluster_discovery | `lualib/skyext/cluster_discovery.lua` | 服务注册/发现 |
| id_generator | `lualib/skyext/id_generator.lua` | snowflake ID 生成（reliable_msg 消息 ID） |
| mongo_conn | `lualib/skyext/mongo_conn.lua` + `service/mongo_conn.lua` | MongoDB 连接池，`CMD.find` 已返回数组 |
| cmd_api | `lualib/skyext/cmd_api.lua` | 服务消息分发 |
| timer | `lualib/skyext/timer.lua` | 超时卸载定时器 |

---

## 文件级实现细节

### 1. `lualib/skyext/entity/types.lua` — 类型注册与路由计算

从 `config.get_table("entity_types")` 读取配置：

```lua
-- 配置格式 (在 etc/nodes/common.app.lua 中定义)
entity_types = {
    guild = {
        db_name = "entity",         -- MongoDB 数据库名
        db_coll = "guild",          -- MongoDB 集合名
        id_field = "gid",           -- 主键字段名
        schema = "guild",           -- ORM schema 名
        agent_count = 4,            -- 每节点 agent 数
        unload_delay = 600,         -- 不活跃后卸载延迟(秒)
        nodes = { "guildnode1", "guildnode2" },  -- 固定节点列表
        client_enabled = false,     -- 是否支持客户端连接（默认 false）
                                    -- true 时启用 client_ext：fd 绑定、sproto 协议分发、
                                    -- 有 fd 时不启动卸载定时器（见 role_entity_migration.md）
        modules_path = "guild_modules", -- 自动扫描该目录下所有模块
    },
}
```

**关键函数：**
- `types.get(type_name)` → 返回类型配置
- `types.calc_node(type_name, entity_id)` → `nodes[jchash.hash(id, #nodes) + 1]`
- `types.calc_agent_index(type_name, entity_id)` → `entity_id % agent_count + 1`
- `types.format_agent_service_name(type_name, index)` → `".entity_agent:guild:1"`

**路由稳定性**：节点列表固定在配置中，jchash 确定性算法，节点重启路由不变。

### 2. `lualib/skyext/entity/router.lua` — 消息路由 API

```lua
local entity_router = require "skyext.entity.router"

-- 同步调用 (有返回值)
local result = entity_router.call("guild", gid, "get_info")

-- 异步发送 (fire-and-forget)
entity_router.send("guild", gid, "on_member_login", rid)

-- 可靠发送 (持久化到 MongoDB，保证送达)
entity_router.reliable_send("guild", gid, "add_item", { item_id = 1001, count = 5 })
```

**路由逻辑：**
1. `types.calc_node()` → 目标节点
2. `types.calc_agent_index()` → agent 索引 → service name
3. 本节点 → `skynet.call/send`
4. 远程 → `cluster.call/send`

**reliable_send 流程：**
1. `reliable_msg.save()` 持久化到 MongoDB
2. 尝试 `send` 立即投递（`__deliver_reliable` 命令）
3. 投递失败则留在 DB，实体加载时自动拉取

### 3. `lualib/skyext/entity/entitymgr.lua` — 实体生命周期

模式同 `rolemgr.lua`，每个 entity_agent 持有一个 entitymgr：

**entity_obj 结构：**
```lua
{
    type_name = "guild",
    id = 12345,
    data = <ORM-wrapped document>,
    entity_mgr = <back-reference>,
    unload_timer = nil,
}
```

**核心流程：**
- `ensure_loaded(entity_id)`:
  1. 缓存命中 → 重置卸载定时器 → 返回
  2. 缓存未命中 → `distributed_lock.try_lock("entity/guild/12345", ...)`
  3. 锁成功 → `dbmgr.load()` → 创建 entity_obj → 初始化各数据模块（`mod.new(entity, data)`） → 依次调用各模块 `mod:on_load()` → 最后调用 `handler.on_load(entity)` → 处理 pending reliable messages → 启动卸载定时器
  4. 锁被其他节点持有 → 报错（说明路由不一致，正常情况不会发生）
- `unload(entity_id)`: 调用 `handler.on_unload(entity)` → 依次调用各模块 `mod:on_unload()` → `distributed_lock.unlock()` → `dbmgr.unload()` → 清缓存
  
**调用时序**：模块的生命周期回调围绕 handler 回调——加载时模块先于 handler 初始化（先有数据再处理业务），卸载时 handler 先于模块清理（先完成业务再释放数据）。
- `touch(entity_id)`: 重置卸载定时器

### 4. `lualib/skyext/entity/reliable_msg.lua` — 可靠消息

MongoDB `entity.entity_msg` 集合，文档：
```
{ msg_id, target_type, target_id, cmd, args, status(0/1), create_time }
```

**函数：**
- `save(target_type, target_id, cmd, args)` → insert → 返回 msg_id
- `load_pending(target_type, target_id)` → `find({status=0})` 按 msg_id 排序
- `mark_delivered(msg_id)` → `$set status=1`

利用已有 `service/mongo_conn.lua` 的 `CMD.find`（cursor→array 已实现）。

**清理策略：** 已投递的消息（`status=1`）通过 MongoDB TTL 索引自动清理，避免文档无限积累：
```lua
-- entity_msg 集合的 TTL 索引，已投递消息 7 天后自动删除
{ "create_time", expireAfterSeconds = 604800, partialFilterExpression = { status = 1 } }
```
该索引在 `etc/nodes/common.app.lua` 的 `mongo_config.entity.collections.entity_msg.indexes` 中声明，由 `mongo_index` 服务自动创建。

### 5. `service/entity_agent.lua` — 通用实体 agent

参数：`skynet.newservice("entity_agent", type_name, agent_index)`

**CMD 表：**
- `CMD.entity_call(entity_id, cmd, ...)` → `ensure_loaded` → `handler[cmd](entity, ...)` → return
- `CMD.entity_send(entity_id, cmd, ...)` → `ensure_loaded` → `handler[cmd](entity, ...)`
- `CMD.__deliver_reliable(entity_id, msg_id, cmd, args)` → `ensure_loaded` → handler → `mark_delivered`
- `CMD.unload_entity(entity_id)` → `entitymgr.unload()`
- `CMD.start(conf)` → 初始化

Handler 模块通过 `require("entity_handler." .. type_name)` 加载。由于 handler 是纯业务逻辑，`entity_handler/` 目录应放在**游戏层** `lualib/`（如 `example/lualib/entity_handler/`），不放在引擎层。引擎仅提供 `example/lualib/entity_handler/example.lua` 作为接入示例。游戏层 `lualib/` 搜索优先级高于引擎层，`require` 时自然命中游戏层的 handler。

**启动时自动加载模块**（见下方模块系统设计）。

### 6. `service/entity_agentmgr.lua` — agent 管理器

参数：`skynet.newservice("entity_agentmgr", type_name)`

启动时：
1. 读取 `agent_count`
2. 调用 `discover_modules(modules_path)` 扫描模块目录（**每个进程只扫这一次**）
3. 循环创建 N 个 entity_agent，将扫描结果通过 `CMD.start` 传入
4. 注册 cluster_discovery

### 7. 模块系统设计

entity 系统内置模块自动发现和管理能力。业务代码只需按约定放置文件，配置中声明模块名，其余全部由框架自动完成。

#### 配置

`entity_types` 中只需配置 `modules_path`：

```lua
entity_types = {
    role = {
        ...
        modules_path = "modules",       -- 自动扫描该目录下所有模块
    },
    guild = {
        ...
        modules_path = "guild_modules",
    },
}
```

**不需要显式列出模块名。** entity_agent 启动时自动扫描 `modules_path` 目录，发现有 `init.lua` 或 `request.lua` 的子目录即为模块。新增模块只需创建目录和文件，无需改配置。

#### 自动发现机制

**`entity_agentmgr` 启动时扫描一次**，将结果传给所有 entity_agent。每个进程只扫一次，entity_agent 不依赖 lfs。

扫描逻辑（在 agentmgr 中，使用项目已有的 `3rd/luafilesystem/`）：

```lua
local lfs = require "lfs"
local skynet = require "skynet"

-- 基于 game_root + 节点 start 名拼接文件系统路径，不依赖 package.path
-- （agentmgr 是引擎层服务，package.path 不一定包含游戏层节点目录）
local function resolve_modules_dir(modules_path, start_name)
    local game_root = skynet.getenv("game_root") or "./"
    local dir = game_root .. "nodes/" .. start_name .. "/" .. modules_path:gsub("%.", "/")
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
        return dir
    end
    return nil
end

-- 扫描目录，返回模块名列表
local function discover_modules(modules_path, start_name)
    local dir = resolve_modules_dir(modules_path, start_name)
    if not dir then return {} end

    local result = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            if lfs.attributes(full, "mode") == "directory" then
                local has_init = lfs.attributes(full .. "/init.lua")
                local has_request = lfs.attributes(full .. "/request.lua")
                if has_init or has_request then
                    result[#result + 1] = entry
                end
            end
        end
    end
    table.sort(result)  -- 确定性顺序
    return result
end
```

agentmgr 扫描后通过 `CMD.start` 传给每个 agent：

```lua
-- entity_agentmgr 中
local start_name = skynet.getenv("start")
local module_names = discover_modules(type_config.modules_path, start_name)

for i = 1, agent_count do
    local agent = skynet.newservice("entity_agent", type_name, i)
    skynet.call(agent, "lua", "start", {
        modules = module_names,
        modules_path = type_config.modules_path,
        ...
    })
end
```

#### 模块文件约定

每个模块是 `modules_path` 下的一个子目录，包含两个可选文件（至少一个）：

```
<modules_path>/<name>/
    init.lua      -- 可选：数据模块，提供 new(entity, data) → module_instance
    request.lua   -- 可选：客户端 sproto 协议处理器（仅 client_enabled 类型有意义）
```

**`init.lua` — 数据模块**：管理 `entity.data.modules.<name>` 下的子数据。

```lua
local M = {}
M.__index = M

function M.new(entity, data)
    return setmetatable({ entity = entity, data = data }, M)
end

-- 可选生命周期回调
function M:on_load() end
function M:on_unload() end

return M
```

**`request.lua` — 客户端协议处理器**：处理 sproto 请求。

```lua
local M = {}

-- 统一签名: handler(request, fd, ctx)
-- request = sproto 解码后的请求数据
-- fd = 客户端 fd
-- ctx = { entity = entity_obj } 由 client_ext.get_obj(fd) 提供
function M.login_info(request, fd, ctx)
    local entity = ctx.entity
    return {
        info = { rid = entity.id, name = entity.data.name },
    }
end

return M
```

#### entity_agent 启动时自动处理

```lua
-- entity_agent CMD.start 中，module_names 由 agentmgr 传入
local modules_path = conf.modules_path
local g_data_modules = {}

for _, name in ipairs(conf.modules) do
    local mod_path = modules_path .. "." .. name

    -- 探测数据模块 (有 init.lua 且导出 new 函数)
    local ok, mod = pcall(require, mod_path)
    if ok and type(mod) == "table" and mod.new then
        g_data_modules[name] = mod
    end

    -- 探测客户端协议 (有 request.lua，且 client_enabled)
    if type_config.client_enabled then
        local ok2, request = pcall(require, mod_path .. ".request")
        if ok2 and type(request) == "table" and next(request) then
            sproto_api.register_module(name, client_ext, request)
        end
    end
end
```

#### ensure_loaded 时自动初始化模块数据

```lua
-- entitymgr.ensure_loaded 内部
if next(g_data_modules) then
    if entity.data.modules == nil then
        entity.data.modules = {}
    end
    entity.modules = {}
    for name, mod in pairs(g_data_modules) do
        if entity.data.modules[name] == nil then
            entity.data.modules[name] = {}
        end
        entity.modules[name] = mod.new(entity, entity.data.modules[name])
    end
end
```

#### 新增模块的完整流程

1. 在 `modules_path` 下创建 `newmod/init.lua` 和/或 `newmod/request.lua`
2. 如有 schema 变更，更新 `schema/<type>.sproto`
3. 完毕。无需改配置、无需修改 handler、无需修改 entity_agent、无需代码生成。

### 8. Handler 模块约定 — `<game>/lualib/entity_handler/<type>.lua`

Handler 只写纯业务逻辑，**不涉及模块注册和数据初始化**：

```lua
-- example/lualib/entity_handler/example.lua
local M = {}

-- 服务端命令（通过 entity_router.call/send 调用）
M.handlers = {}

function M.handlers.get_info(entity)
    return { name = entity.data.name }
end

function M.handlers.set_name(entity, name)
    entity.data.name = name
    return true
end

-- 生命周期回调（全部可选）
function M.on_load(entity) end
function M.on_unload(entity) end

return M
```

---

## 修改的现有文件

### `etc/nodes/common.app.lua`
添加 entity DB 配置和 entity_types 模板（空表）：
```lua
mongo_config.entity = {
    connections = 4,
    cfg = { host = "127.0.0.1", port = 27017 },
    collections = {
        entity_msg = {
            indexes = {
                { "target_type", "target_id", "status", background = true },
                { "create_time", expireAfterSeconds = 604800, partialFilterExpression = { status = 1 }, background = true },
            },
        },
    },
}
entity_types = {}
```

### `lualib/errcode.lua`（引擎层）
添加 Entity 通用错误码（引擎保留范围 0-99），如 `ENTITY_NOT_FOUND`、`ENTITY_LOCK_FAILED` 等。游戏层业务错误码（100+）由游戏层 `errcode.lua` 扩展定义（见 `directory_restructure.md` 错误码分层设计）。

---

## 新文件清单

| 文件 | 说明 |
|------|------|
| `lualib/skyext/entity/types.lua` | 实体类型注册与路由计算 |
| `lualib/skyext/entity/router.lua` | call / send / reliable_send API |
| `lualib/skyext/entity/entitymgr.lua` | 实体生命周期管理 |
| `lualib/skyext/entity/reliable_msg.lua` | 可靠消息持久化 |
| `service/entity_agent.lua` | 通用实体 agent 服务 |
| `service/entity_agentmgr.lua` | agent 管理器 |
| `example/lualib/entity_handler/example.lua` | 示例 handler（展示接入方式，游戏层文件） |

## 修改文件清单

| 文件 | 修改内容 |
|------|----------|
| `etc/nodes/common.app.lua` | 添加 entity_types 和 entity DB 配置 |
| `lualib/errcode.lua` | 添加 Entity 通用错误码（引擎保留范围 0-99） |

---

## 与现有 roleagent 的关系

**新增并行系统，不修改现有 roleagent 代码。** roleagent 继续原样工作。未来可将 role 迁移为一种 entity type，但不在本次范围内。

---

## 验证方案

1. **启动测试**：配置一个 example entity type，启动 entity_agentmgr，验证 N 个 entity_agent 正常注册到 cluster_discovery
2. **路由测试**：通过 `router.call("example", id, "get_info")` 验证消息路由到正确 agent
3. **路由稳定性**：重启节点，同一 entity_id 路由到同一节点
4. **reliable_send**：发送消息 → 验证 MongoDB 有记录 → 加载 entity → 验证消息被处理且标记 delivered
5. **分布式锁**：两节点同时 load 同一 entity，仅一个成功
6. **卸载**：entity 空闲 `unload_delay` 秒后自动卸载，数据已存盘

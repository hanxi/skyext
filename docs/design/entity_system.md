# 通用实体系统

> **状态：已实现。** 核心组件（types / router / entitymgr / reliable_msg / client_ext / entity_agent / entity_agentmgr）均已合入主线。`role` 类型已通过 entity 系统运行——`example/nodes/role/watchdog.lua` 直接创建 `entity_agentmgr("role")`，旧版 roleagent / rolemgr 已移除。登录流程中变量名 `roleagentmgr` 是历史命名，实际指向 `entity_agentmgr` 服务。

## 概述

原先 `roleagent` 系统与 role 实体强耦合。若要支持公会、场景、怪物等其他实体，需要为每种类型复制一整套 agent/agentmgr/api 代码。entity 系统将此架构泛化：新增实体类型需配置节点、业务数据库与 schema，并提供 handler；随后可复用生命周期管理和消息路由等基础组件。

**核心能力：**
- Entity ID 稳定不变（snowflake ID）
- 节点重启路由不变（jchash + 固定节点列表）
- 支持 `call`（同步）、`send`（异步）、`reliable_send`（持久化消息，实体加载时重试投递）
- 可选客户端连接绑定（`client_enabled`）

---

## 架构总览

```
任意 Service                    entity_agent:role:1 (skynet service)
     |                                  |
     | router.call("role", rid, cmd)    |
     |--------------------------------->| entity_call(rid, cmd, ...)
     |                                  |   -> entitymgr.ensure_loaded(rid)
     |  (local: skynet.call)            |   -> handler[cmd](entity, ...)
     |  (remote: cluster.call)          |
     |<---------------------------------| return result
```

**组件一览：**

| 文件 | 职责 |
|------|------|
| `lualib/skyext/entity/types.lua` | 实体类型注册表，路由计算（jchash 选节点，modulo 选 agent） |
| `lualib/skyext/entity/router.lua` | 公共 API：call / send / reliable_send，自动路由到正确节点 |
| `lualib/skyext/entity/entitymgr.lua` | 单 agent 内实体生命周期（加载/卸载/缓存），复用 dbmgr + distributed_lock |
| `lualib/skyext/entity/reliable_msg.lua` | 可靠消息持久化（MongoDB），加载时投递 pending 消息 |
| `lualib/skyext/entity/client_ext.lua` | 客户端 fd 绑定/解绑，仅 `client_enabled` 类型启用 |
| `service/entity_agent.lua` | 通用实体 agent 服务，按 type 参数化 |
| `service/entity_agentmgr.lua` | agent 管理器，负责模块扫描和 agent 创建 |

---

## 复用的现有组件

| 组件 | 路径 | 用途 |
|------|------|------|
| jchash | `lualib-src/jchash.c` | `jchash.hash(key, buckets)` 确定性路由 |
| distributed_lock | `lualib/skyext/distributed_lock.lua` | etcd 分布式锁，用于协调跨节点实体加载 |
| dbmgr | `lualib/skyext/dbmgr.lua` | MongoDB ORM 加载/存盘/卸载，含脏数据定时刷盘 |
| cluster_discovery | `lualib/skyext/cluster_discovery.lua` | 服务注册/发现 |
| id_generator | `lualib/skyext/id_generator.lua` | snowflake ID 生成（reliable_msg 消息 ID） |
| mongo_conn | `lualib/skyext/mongo_conn.lua` + `service/mongo_conn.lua` | MongoDB 连接池 |
| cmd_api | `lualib/skyext/cmd_api.lua` | 服务消息分发 |
| timer | `lualib/skyext/timer.lua` | 超时卸载定时器 |

---

## 实现细节

### 1. types.lua — 类型注册与路由计算

从 `config.get_table("entity_types")` 读取配置。当前 `example/etc/nodes/common.app.lua` 中已配置 `role` 类型：

```lua
entity_types = {
    role = {
        db_name = "role",           -- MongoDB 数据库名
        db_coll = "role",           -- MongoDB 集合名
        id_field = "rid",           -- 主键字段名
        schema = "role",            -- ORM schema 名
        agent_count = 2,            -- 每节点 agent 数
        unload_delay = 300,         -- 不活跃后卸载延迟(秒)
        nodes = { "rolenode1", "rolenode2" },  -- 固定节点列表
        client_enabled = true,      -- 启用客户端连接（fd 绑定、sproto 协议分发）
                                    -- 有 fd 时不启动卸载定时器
        modules_path = "modules",   -- 自动扫描该目录下所有模块
    },
}
```

新增实体类型只需在此表中添加条目，例如：

```lua
entity_types = {
    role = { ... },
    guild = {
        db_name = "entity",
        db_coll = "guild",
        id_field = "gid",
        schema = "guild",
        agent_count = 4,
        unload_delay = 600,
        nodes = { "guildnode1", "guildnode2" },
        client_enabled = false,
        modules_path = "guild_modules",
    },
}
```

**关键函数：**
- `types.get(type_name)` — 返回类型配置，未知类型抛错
- `types.all()` — 返回全部类型配置
- `types.calc_node(type_name, entity_id)` — `nodes[jchash.hash(id, #nodes) + 1]`
- `types.calc_agent_index(type_name, entity_id)` — `entity_id % agent_count + 1`
- `types.format_agent_service_name(type_name, index)` — 如 `".entity_agent:role:1"`

**路由稳定性**：节点列表固定在配置中，jchash 确定性算法，节点重启路由不变；这不等于自动故障转移，所选节点不可用时调用可能失败。修改节点列表也会改变部分实体的路由，需要规划数据与锁的迁移。

### 2. router.lua — 消息路由 API

```lua
local entity_router = require "skyext.entity.router"

-- 同步调用（有返回值）
local result = entity_router.call("role", rid, "get_online_info")

-- 异步发送（fire-and-forget）
entity_router.send("role", rid, "on_event", event_data)

-- 可靠发送（持久化到 MongoDB，实体加载时自动重试）
entity_router.reliable_send("role", rid, "add_item", { item_id = 1001, count = 5 })
```

**路由逻辑：**
1. `types.calc_node()` 确定目标节点
2. `types.calc_agent_index()` 确定 agent 索引，拼出 service name
3. 通过 `config.get("cluster_node_name")` 判断本节点
4. 本节点 → `skynet.call/send`；远程 → `cluster.call/send`

**reliable_send 流程：**
1. `reliable_msg.save()` 持久化到 MongoDB
2. 尝试 `send` 立即投递（`__deliver_reliable` 命令）
3. 即时 `send` 抛错时记录警告；已保存但未标记投递的消息会在实体加载时被拉取并重试（`save` 自身失败仍会抛错）

这不是 exactly-once 保证：即时投递和加载时的异步重试可能重叠；处理器应自行保证幂等。目标节点不可用、数据库故障或处理器报错时，投递也可能失败，当前没有针对已加载实体的周期性重试机制；如果找不到对应 handler，现有实现会把消息标记为已投递并丢弃。

### 3. entitymgr.lua — 实体生命周期

每个 entity_agent 持有一个 entitymgr 实例，通过 `M.new(type_name, type_config, handler, data_modules)` 创建。

**entity_obj 结构：**
```lua
{
    type_name = "role",
    id = 12345,
    data = <ORM-wrapped document>,
    entity_mgr = <back-reference>,
    modules = { name = <module_instance>, ... },  -- 数据模块实例（若有）
    fd = nil,           -- 客户端连接（仅 client_enabled 类型）
    unload_timer = nil,
}
```

**ensure_loaded(entity_id) 流程：**
1. 缓存命中 → 重置卸载定时器 → 返回
2. 缓存未命中 → `distributed_lock.try_lock(lock_key, lock_value)`
   - lock_key 格式：`"entity/role/12345"`
   - lock_value 编码节点名（如 `"rolenode1/role"`），供冲突时识别持锁节点
3. 锁成功 → `dbmgr.load()` → 创建 entity_obj → `_init_modules`（`mod.new()`） → `_call_modules_on_load`（`mod:on_load()`） → `handler.on_load(entity)` → **异步** `skynet.fork` 投递 pending reliable messages → 启动卸载定时器
4. 锁失败 → 返回 `false` 和锁信息（持锁节点标识）

**unload(entity_id) 流程：**
1. 取消卸载定时器
2. `handler.on_unload(entity)` → `_call_modules_on_unload`（`mod:on_unload()`）
3. `distributed_lock.unlock()` → `dbmgr.unload()` → 清缓存

**调用时序**：加载时模块先于 handler 初始化（先有数据再处理业务），卸载时 handler 先于模块清理（先完成业务再释放数据）。

**touch(entity_id)**：重置卸载定时器。若 `entity.fd` 存在（有客户端连接），跳过——有连接的实体不设卸载定时器。

### 4. reliable_msg.lua — 可靠消息

MongoDB `entity.entity_msg` 集合，文档结构：
```
{ msg_id, target_type, target_id, cmd, args, status(0/1), create_time }
```

**函数：**
- `save(target_type, target_id, cmd, args)` — insert，返回 msg_id（snowflake ID）
- `load_pending(target_type, target_id)` — 查询 `{status=0}` 按 msg_id 排序，逐条 cursor 迭代返回数组
- `mark_delivered(msg_id)` — `findAndModify` 将 status 置 1

**清理策略：** 已投递消息（`status=1`）通过 MongoDB TTL 索引自动清理（7 天），索引在 `common.app.lua` 的 `mongo_config.entity.collections.entity_msg.indexes` 中声明，由 `mongo_index` 服务自动创建：

```lua
{ "create_time", expireAfterSeconds = 604800,
  partialFilterExpression = { status = 1 }, background = true },
```

### 5. client_ext.lua — 客户端连接管理

仅在 `client_enabled = true` 的实体类型中由 entity_agent 加载。维护 fd → entity 映射。

**核心函数：**
- `init(entitymgr)` — 注入 entitymgr 引用，供 unbind 时触发 touch
- `bind(fd, entity)` — 绑定 fd 到 entity，设置 `entity.fd`，取消卸载定时器
- `unbind(fd)` — 解绑，清除 `entity.fd`，调用 `entitymgr:touch` 重启卸载定时器
- `unbind_kick(fd)` — 解绑并通知 gate 踢掉连接
- `get_entity(fd)` / `get_obj(fd)` — 按 fd 查找 entity 或返回 `{ entity = entity }` 上下文

**客户端重连逻辑**（在 `entity_agent.lua` 的 `CMD.bind_client` 中实现）：
1. 尝试在本节点加载 entity（`try_ensure_loaded`）
2. 若 entity 被其他节点锁定，尝试通过 cluster 请求持锁节点执行 `unload_entity`；当前锁值为 `"rolenode1/role"` 形式，但代码直接把它作为 cluster 节点名使用，跨节点重连可能失败（见「已知问题」）
3. 卸载成功后在本节点重新加载
4. 已有旧 fd 连接时先 `unbind_kick` 踢掉旧连接
5. 绑定新 fd，通知 watchdog forward 后续消息

### 6. entity_agent.lua — 通用实体 agent

参数：`skynet.newservice("entity_agent", type_name, agent_index)`

启动时注册服务名（如 `.entity_agent:role:1`），若 `client_enabled` 则加载 client_ext。

**CMD 表：**
- `CMD.entity_call(entity_id, cmd, ...)` — `ensure_loaded` → `handler.handlers[cmd](entity, ...)` → return
- `CMD.entity_send(entity_id, cmd, ...)` — 同上但无返回值
- `CMD.__deliver_reliable(entity_id, msg_id, cmd, args)` — `ensure_loaded` → handler → `mark_delivered`
- `CMD.unload_entity(entity_id)` — 强制卸载（供重连流程跨节点调用）
- `CMD.bind_client(entity_id, fd)` — 客户端绑定（含重连逻辑，见上节）
- `CMD.disconnect(fd)` — 客户端断开，触发 unbind + handler 回调
- `CMD.start(conf)` — 初始化：加载数据模块和 sproto 协议、`require` handler、创建 entitymgr

Handler 通过 `require("entity_handler." .. type_name)` 加载。handler 是游戏层代码，放在 `example/lualib/entity_handler/`，Lua `require` 搜索路径自然优先命中游戏层。

### 7. entity_agentmgr.lua — agent 管理器

参数：`skynet.newservice("entity_agentmgr", type_name)`

启动流程：
1. 读取 `agent_count`
2. 调用 `discover_modules(modules_path, start_name)` 通过 luafilesystem 扫描模块目录（每个进程只扫一次）
3. 循环创建 N 个 entity_agent，通过 `CMD.start` 传入扫描结果和 watchdog 地址
4. 注册 cluster_discovery（`"entity:" .. type_name`）

**模块扫描路径解析**：基于 `game_root` + 节点 `start` 名拼接文件系统路径：

```lua
game_root .. "nodes/" .. start_name .. "/" .. modules_path:gsub("%.", "/")
```

不依赖 `package.path`（agentmgr 是引擎层服务，package.path 不一定包含游戏层节点目录）。扫描逻辑：遍历目录下所有子目录，含 `init.lua` 或 `request.lua` 的子目录即为模块，按名称排序保证确定性顺序。

---

## 模块系统

业务代码只需按约定放置文件，框架自动发现和管理。

### 配置

`entity_types` 中配置 `modules_path` 即可，**不需要显式列出模块名**。agentmgr 启动时自动扫描目录，将结果传给所有 entity_agent。当前 role 类型配置 `modules_path = "modules"`，对应目录 `example/nodes/role/modules/`，已有 `bag`、`role`、`mail` 三个模块。

### 模块文件约定

每个模块是 `modules_path` 下的一个子目录，包含两个可选文件（至少一个）：

```
<modules_path>/<name>/
    init.lua      -- 可选：数据模块，提供 new(entity, data) → module_instance
    request.lua   -- 可选：客户端 sproto 协议处理器（仅 client_enabled 类型有意义）
```

**init.lua — 数据模块**：管理 `entity.data.modules.<name>` 下的子数据。

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

**request.lua — 客户端协议处理器**（仅 `client_enabled` 类型有意义）：

```lua
local M = {}

-- 统一签名: handler(request, fd, ctx)
-- request = sproto 解码后的请求数据
-- fd = 客户端 fd
-- ctx = { entity = entity_obj }，由 client_ext.get_obj(fd) 提供
function M.login_info(request, fd, ctx)
    local entity = ctx.entity
    return { info = { rid = entity.id, name = entity.data.name } }
end

return M
```

### entity_agent 启动时自动加载

agentmgr 传入 module_names 后，entity_agent 在 `CMD.start` 中对每个模块：
1. 尝试 `require(modules_path .. "." .. name)`，若导出 `new` 函数则注册为数据模块
2. 若 `client_enabled`，尝试 `require(modules_path .. "." .. name .. ".request")`，有内容则注册到 `sproto_api`

### ensure_loaded 时自动初始化

加载实体时为每个数据模块：初始化 `entity.data.modules[name]`（若不存在则创建空表），调用 `mod.new(entity, data)` 创建 module_instance 存入 `entity.modules[name]`。

### 新增模块流程

1. 在 `modules_path` 下创建 `newmod/init.lua` 和/或 `newmod/request.lua`
2. 如有 schema 变更，更新对应 sproto 文件
3. 完毕。无需改配置、无需修改 handler、无需修改 entity_agent。

---

## Handler 约定

Handler 放在游戏层 `example/lualib/entity_handler/<type>.lua`，只写纯业务逻辑：

```lua
-- example/lualib/entity_handler/example.lua
local M = {}

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

-- 客户端连接回调（仅 client_enabled 类型，可选）
function M.on_bind_client(entity, fd) end
function M.on_unbind_client(entity) end

return M
```

当前已有两个 handler：
- `example/lualib/entity_handler/example.lua` — 接入示例（get_info / set_name）
- `example/lualib/entity_handler/role.lua` — 角色实体（含 get_online_info / kick / 客户端连接回调）

---

## 数据库配置

`example/etc/nodes/common.app.lua` 中 reliable_msg 使用的 MongoDB 配置：

```lua
mongo_config.entity = {
    connections = 4,
    cfg = { host = "127.0.0.1", port = 27017 },
    collections = {
        entity_msg = {
            indexes = {
                { "target_type", "target_id", "status", background = true },
                { "create_time", expireAfterSeconds = 604800,
                  partialFilterExpression = { status = 1 }, background = true },
            },
        },
    },
}
```

注意各实体类型的业务数据库由各自 `db_name` / `db_coll` 配置决定（如 role 使用 `mongo_config.role`），`mongo_config.entity` 仅用于可靠消息。

---

## 文件清单

**引擎层：**

| 文件 | 说明 |
|------|------|
| `lualib/skyext/entity/types.lua` | 实体类型注册与路由计算 |
| `lualib/skyext/entity/router.lua` | call / send / reliable_send API |
| `lualib/skyext/entity/entitymgr.lua` | 实体生命周期管理 |
| `lualib/skyext/entity/reliable_msg.lua` | 可靠消息持久化 |
| `lualib/skyext/entity/client_ext.lua` | 客户端 fd 绑定管理 |
| `service/entity_agent.lua` | 通用实体 agent 服务 |
| `service/entity_agentmgr.lua` | agent 管理器 |

**游戏层（example）：**

| 文件 | 说明 |
|------|------|
| `example/lualib/entity_handler/example.lua` | 接入示例 handler |
| `example/lualib/entity_handler/role.lua` | 角色 handler（含客户端连接） |
| `example/nodes/role/modules/bag/` | 角色背包模块（init + request） |
| `example/nodes/role/modules/role/` | 角色基础模块（request） |
| `example/nodes/role/modules/mail/` | 角色邮件模块（init + request） |

**修改过的现有文件：**

| 文件 | 修改内容 |
|------|----------|
| `example/etc/nodes/common.app.lua` | 添加 `entity_types` 配置和 `mongo_config.entity` |
| `lualib/skyext/errcode.lua` | 添加 `ENTITY_NOT_FOUND`(20) / `ENTITY_LOCK_FAILED`(21) / `ENTITY_LOAD_FAILED`(22) |

---

## 已知问题

- `errcode.lua` 中 `LOCAK_FAILED = 4` 是拼写错误（应为 `LOCK_FAILED`），`entity_agent.lua` 的 `CMD.entity_call` 和 `CMD.bind_client` 引用了该常量。修复需同时改 `errcode.lua` 和所有引用处。
- `entitymgr.make_lock_value` 把节点和类型拼成 `"rolenode1/role"`，但 `entity_agent.CMD.bind_client` 将竞争锁时返回的整个锁值直接传给 `cluster.call` 作为节点名；配置中的节点名是 `"rolenode1"`。跨节点重连需先正确解析持锁节点，不能将现有逻辑视为已验证可用。

---

## 验证方法

1. **启动测试**：配置实体类型，启动 entity_agentmgr，验证 N 个 entity_agent 正常注册到 cluster_discovery
2. **路由测试**：通过 `router.call("role", rid, "get_online_info")` 验证消息路由到正确 agent
3. **路由稳定性**：重启节点，同一 entity_id 路由到同一节点
4. **reliable_send**：发送消息 → 验证 MongoDB 有记录 → 加载 entity → 验证消息被处理且标记 delivered
5. **分布式锁**：两节点同时 load 同一 entity，仅一个成功
6. **卸载**：entity 空闲 `unload_delay` 秒后自动卸载，数据已存盘
7. **客户端重连**：客户端断线后重连到另一节点，旧节点 entity 被卸载，新节点正常加载并绑定 fd

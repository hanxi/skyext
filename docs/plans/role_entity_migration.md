# Role 迁移到 Entity 系统设计方案

## Context

在通用 Entity 系统（见 `entity_system_design.md`）实现之后，需要将现有的 `roleagent` 重构为基于 Entity 的实现。这样做的好处：

1. **消除重复代码**：roleagent 中的生命周期管理（加载/卸载/缓存）、分布式锁、节点路由等逻辑全部复用 Entity 系统
2. **启用 jchash 路由**：当前 `rolenode_api.calc_rolenode()` 硬编码返回 `"rolenode1"`，迁移后自动使用 jchash 稳定路由
3. **统一消息模型**：其他实体（公会、场景）可以通过 `entity_router.call("role", rid, ...)` 与角色通信，无需特殊通道
4. **支持 reliable_send**：其他系统可以向离线角色发送可靠消息（如公会奖励、邮件），角色上线时自动收到

**核心挑战**：角色实体与公会等纯服务端实体的关键区别——角色有 **客户端连接**（TCP fd + sproto 协议）。Entity 系统需要扩展以支持客户端协议分发。

---

## 当前 roleagent 架构梳理

```
watchdog
  ├── gate (TCP 连接管理)
  ├── login (认证 + sproto 协议: login.login / login.report_remote_addr)
  │     └── 认证成功后: skynet.call(roleagent, "load_bind_role", rid, fd)
  │           → watchdog.forward(fd, roleagent)  -- 后续 client 包直接到 roleagent
  │           → login.client.unbind(fd)
  └── roleagentmgr
        ├── roleagent:1  (PTYPE_CLIENT 分发 → sproto_api → modules/role,bag,mail 的 request.lua)
        └── roleagent:2
```

**涉及文件：**

| 文件 | 职责 | 迁移后去向 |
|------|------|-----------|
| `app/role/roleagentmgr.lua` | 启动 N 个 roleagent | **删除**，由 `entity_agentmgr` 替代 |
| `app/role/roleagent/main.lua` | agent 服务主体：load_bind_role、unload、disconnect | **删除**，由 `entity_agent` + handler 替代 |
| `app/role/roleagent/rolemgr.lua` | 角色加载/卸载/缓存 | **删除**，由 `entitymgr` 替代 |
| `app/role/roleagent/client.lua` | fd-role 绑定管理 | **迁移**到 `entity/client_ext.lua`（通用客户端扩展） |
| `app/role/roleagent/global.lua` | watchdog/agentmgr 地址共享 | **删除**，改为 entity_agent 的 conf |
| `app/role/roleagent/modules/init.lua` | 自动生成的模块注册 | **删除**，entity 系统自动发现 |
| `app/role/roleagent/modules/role/init.lua` | role 对象 + 离线卸载定时器 | **删除**，entity 对象本身即 role，卸载由 entitymgr 管理 |
| `app/role/roleagent/modules/role/request.lua` | sproto handler | **重构**：签名改为 `(request, fd, ctx)`，通过 `ctx.entity` 访问实体 |
| `app/role/roleagent/modules/bag/init.lua` | bag 数据模块 | **重构**：构造函数签名改为 `new(entity, data)` |
| `app/role/roleagent/modules/bag/request.lua` | bag sproto handler | **重构**：同 role/request.lua |
| `app/role/roleagent/modules/mail/init.lua` | mail 数据模块 | **重构**：同 bag/init.lua |
| `app/role/roleagent/modules/mail/request.lua` | mail sproto handler | **重构**：同 role/request.lua |
| `tools/gen_roleagent_modules.lua` | 代码生成器 | **删除**，entity 系统自动发现替代 |
| `app/role/lualib/roleagent_api.lua` | rid→agent 路由 | **删除**，由 `entity/types.lua` 替代 |
| `lualib/rolenode_api.lua` | rid→node 路由 (硬编码) | **删除**，由 `entity/types.lua` jchash 替代 |
| `app/role/login/login_request.lua` | 登录流程，调用 roleagent_api | **修改**，改用 entity_router |
| `app/role/watchdog.lua` | gate/fd 管理 | **少量修改**，创建 entity_agentmgr 替代 roleagentmgr |
| `app/role/main.lua` | 节点启动入口 | **少量修改** |
| `tools/gen_roleagent_modules.lua` | 代码生成器 | **删除**，不再需要自动生成，手写注册更直观 |
| `app/role/roleagent/modules/init.lua` | 自动生成的模块注册 | **删除**，注册逻辑移入 `entity_handler/role.lua` |

---

## Entity 系统扩展：客户端连接支持

角色实体需要处理客户端 TCP 连接和 sproto 协议。这不是 Entity 核心能力，而是一个**可选扩展**。

### 新增文件：`lualib/entity/client_ext.lua`

为 entity_agent 提供客户端连接管理能力：

```lua
local client_ext = require "entity.client_ext"

-- 初始化（在 entity_agent 的 skynet.start 中，仅 client_enabled 类型调用）
client_ext.init(entitymgr, handler_module)

-- 绑定客户端 fd 到实体
client_ext.bind(fd, entity_obj)

-- 解绑
client_ext.unbind(fd)

-- 通过 fd 查找实体
client_ext.get_entity(fd)  --> entity_obj or nil
```

**内部维护：**
- `g_fd_map = {}` — fd → entity_obj 的映射（同现有 `roleagent/client.lua`）
- 注册 `PTYPE_CLIENT` 协议处理（同现有 `sproto_api` 模式）
- sproto 请求分发到 handler 模块的 `client_handlers`

### entity_types 配置扩展

```lua
entity_types = {
    role = {
        db_name = "role",
        db_coll = "role",
        id_field = "rid",
        schema = "role",
        agent_count = 2,
        unload_delay = 300,
        nodes = { "rolenode1", "rolenode2" },
        client_enabled = true,
        modules_path = "modules",  -- 自动扫描，无需列模块名
    },
}
```

### entity_agent.lua 对 client_enabled 的处理

```lua
-- service/entity_agent.lua 启动时
local type_config = entity_types.get(g_type_name)
if type_config.client_enabled then
    local client_ext = require "entity.client_ext"
    client_ext.init(entitymgr, handler_module)
end

-- 新增 CMD
function CMD.bind_client(entity_id, fd)
    local entity = entitymgr.ensure_loaded(entity_id)
    client_ext.bind(fd, entity)
    -- 通知 handler
    if handler_module.on_bind_client then
        handler_module.on_bind_client(entity, fd)
    end
    return true
end

function CMD.disconnect(fd)
    local entity = client_ext.get_entity(fd)
    if entity then
        client_ext.unbind(fd)
        if handler_module.on_unbind_client then
            handler_module.on_unbind_client(entity)
        end
    end
end
```

---

## Role Handler 模块设计

### `example/lualib/entity_handler/role.lua`

Handler **只写纯业务逻辑**。模块注册、sproto 注册、数据初始化全部由 entity 系统根据配置自动完成（见 `entity_system_design.md` 模块系统设计章节）。

```lua
local M = {}

-- ====== 服务端命令 (通过 entity_router.call/send 调用) ======
M.handlers = {}

function M.handlers.get_online_info(entity)
    if not entity.fd then
        return nil
    end
    return { rid = entity.id, name = entity.data.name }
end

function M.handlers.kick(entity)
    if entity.fd then
        local client_ext = require "entity.client_ext"
        client_ext.unbind_kick(entity.fd)
    end
    return true
end

-- ====== 生命周期回调（全部可选） ======

function M.on_load(entity) end
function M.on_unload(entity) end

function M.on_bind_client(entity, fd)
    entity.fd = fd
end

function M.on_unbind_client(entity)
    entity.fd = nil
end

return M
```

**无需在 handler 中写任何模块相关代码。** 对比现有 roleagent 需要维护的内容：
- ~~`modules/init.lua` 自动生成文件~~ → entity 系统自动发现
- ~~`rolemgr.lua` 手动加载模块~~ → entitymgr 自动初始化
- ~~`sproto_api.register_module` 手动注册~~ → entity_agent 启动时自动注册

### 模块代码重构

现有模块按新约定重构。核心变化：

1. **统一 request handler 签名**：`handler(request, fd, ctx)` 其中 `ctx.entity` 为实体对象
2. **统一 init.lua 构造签名**：`mod.new(entity, data)` 其中 `entity` 为实体对象
3. **去掉 `role_obj` 间接引用**：直接通过 `ctx.entity` 或 `self.entity` 访问

#### `modules/role/request.lua`（重构）

```lua
local log = require "log"
local time = require "time"
local res = require "res"

local M = {}

function M.login_info(request, fd, ctx)
    local entity = ctx.entity
    entity.data.last_login_time = time.now_ms()
    return {
        info = {
            rid = entity.id,
            name = entity.data.name,
        },
    }
end

return M
```

注意：role 模块不再需要 `init.lua`，因为 entity 对象本身就是 "role 对象"。

#### `modules/bag/init.lua`（重构）

```lua
local log = require "log"

local M = {}
M.__index = M

function M.new(entity, data)
    log.info("creating bag module", "entity_id", entity.id)
    return setmetatable({ entity = entity, data = data }, M)
end

function M:add_item(res_type, res_id, count)
    -- 业务逻辑
end

return M
```

#### `modules/bag/request.lua`（重构）

```lua
local M = {}

function M.get_bag(request, fd, ctx)
    local bag = ctx.entity.modules.bag
    return { items = bag.data }
end

return M
```

#### `modules/mail/init.lua`（重构，同 bag 模式）

```lua
local log = require "log"

local M = {}
M.__index = M

function M.new(entity, data)
    log.info("creating mail module", "entity_id", entity.id)
    return setmetatable({ entity = entity, data = data }, M)
end

return M
```

### client_ext 中的 sproto 分发

`client_ext` 提供 `get_obj(fd)` 和可选的 `middleware_cbs`，满足 `sproto_api.register_module(mod_name, module, cmds)` 的第二个参数约定（`sproto_api` 调用 `module.get_obj(fd)` 获取上下文对象，并将其作为第三参数传给 handler）：

```lua
-- client_ext 实现 sproto_api 要求的接口
-- sproto_api 会将 get_obj 返回值作为 handler 的第三参数 (request, fd, ctx)
function M.get_obj(fd)
    local entity = g_fd_map[fd]
    if not entity then return nil end
    return { entity = entity }
end

-- 可选：中间件回调（如协议拦截/频率限制），sproto_api 会在分发前依次调用
M.middleware_cbs = {}
```

**`sproto_api.lua` 本身无需修改**——它已经是透传 `get_obj` 返回值作为第三参数的通用设计。迁移只是把 `client.lua`（返回 `client_obj`，含 `role_obj`）替换为 `client_ext`（返回 `ctx`，含 `entity`），handler 签名从 `(request, fd, client_obj)` 变为 `(request, fd, ctx)`。

sproto 协议注册由 entity_agent 启动时自动完成（遍历模块目录，探测 `request.lua`，调用 `sproto_api.register_module(mod_name, client_ext, request_handlers)`）。handler 和模块代码均无需感知注册过程。

---

## 登录流程变更

### 修改：`app/role/login/login_request.lua`

```lua
-- 现有代码:
local roleagent_api = require "roleagent_api"
local function load_bind_role(fd, rid)
    local agent_addr = roleagent_api.calc_agent_addr(rid)
    local code, rolenode = skynet.call(agent_addr, "lua", "load_bind_role", rid, fd)
    ...
end

-- 迁移后:
local entity_types = require "entity.types"
local config = require "config"
local cluster = require "skynet.cluster"

local g_self_node = config.get("cluster_node_name")

local function load_bind_role(fd, rid)
    -- 检查是否在正确节点
    local target_node = entity_types.calc_node("role", rid)
    if target_node ~= g_self_node then
        return { code = errcode.NOT_THIS_NODE, rolenode = target_node }
    end

    -- bind_client 是 agent 级操作（fd 转发），直接 skynet.call 本地 agent，不走 entity_router
    local agent_index = entity_types.calc_agent_index("role", rid)
    local agent_name = entity_types.format_agent_service_name("role", agent_index)
    local agent_addr = skynet.localname(agent_name)

    local code = skynet.call(agent_addr, "lua", "bind_client", rid, fd)
    if code ~= errcode.OK then
        return { code = code }
    end

    client.unbind(fd)
    return { code = errcode.OK, rid = rid }
end
```

`bind_client` 是 entity_agent 的内置 CMD 命令（不走 handler 分发），因为它需要操作 agent 级别的 fd 转发和分布式锁。entity_agent 收到后的完整流程（**保留了现有 roleagent 的锁冲突处理逻辑**）：

```lua
function CMD.bind_client(entity_id, fd)
    -- 1. 尝试加载实体（含分布式锁）
    local ok, lock_info = entitymgr.try_ensure_loaded(entity_id)
    if not ok then
        if not lock_info then
            return errcode.LOCAK_FAILED
        end
        -- 锁被其他节点持有 → 通知对方卸载 → 重试
        local holder_node = lock_info.value.node
        local holder_agent = entity_types.format_agent_service_name("role",
            entity_types.calc_agent_index("role", entity_id))
        local ret = cluster.call(holder_node, holder_agent, "unload_entity", entity_id)
        if not ret then
            return errcode.IN_OTHER_NODE
        end
        -- 再次尝试
        ok, lock_info = entitymgr.try_ensure_loaded(entity_id)
        if not ok then
            return errcode.LOCAK_FAILED
        end
    end

    local entity = entitymgr.get(entity_id)

    -- 2. 如果已有 fd，踢掉旧连接
    if entity.fd then
        client_ext.unbind_kick(entity.fd)
    end

    -- 3. 绑定 fd
    client_ext.bind(fd, entity)

    -- 4. 通知 watchdog 转发后续客户端包到本 agent
    skynet.call(g_watchdog, "lua", "forward", fd, skynet.self())

    -- 5. 通知 handler
    if handler_module.on_bind_client then
        handler_module.on_bind_client(entity, fd)
    end

    return errcode.OK
end
```

这样完整保留了现有 `roleagent/main.lua` 中"锁冲突 → 远程卸载 → 重试"的关键逻辑。

### 修改：`app/role/watchdog.lua`

```lua
-- 现有:
g_roleagentmgr_service = skynet.newservice("roleagentmgr")

-- 迁移后:
g_entity_agentmgr_service = skynet.newservice("entity_agentmgr", "role")
```

`CMD.start` 中相应调整服务名。login 服务的启动不变。

### 修改：`app/role/main.lua`

无实质变更，watchdog 内部处理了 agentmgr 的切换。

---

## entitymgr 对 client_enabled 实体的特殊处理

对于 `client_enabled = true` 的实体类型，卸载策略有所不同：

**普通实体**：`unload_delay` 秒无消息后自动卸载
**客户端实体**：
- 有 fd 绑定时：**不启动卸载定时器**（客户端在线）
- fd 解绑时（断线）：启动 `unload_delay` 秒卸载定时器
- 收到新消息时（`touch`）：重置定时器

**fd 设置时序**：`ensure_loaded` 加载实体时 `fd = nil`，此时 `touch()` 会正常启动卸载定时器——这是预期行为，因为实体刚加载还未绑定客户端。随后 `CMD.bind_client` 调用 `client_ext.bind` 设置 `entity.fd`，同时取消卸载定时器。整个过程在同一协程内同步完成，不会出现实体在定时器到期前被意外卸载的情况。

```lua
-- entitymgr.lua 中
function M.touch(entity_id)
    local entity = g_entities[entity_id]
    if not entity then return end

    -- client_enabled 且有 fd 时不需要定时器
    if g_type_config.client_enabled and entity.fd then
        if entity.unload_timer then
            entity.unload_timer:cancel()
            entity.unload_timer = nil
        end
        return
    end

    reset_unload_timer(entity)
end
```

---

## entity_obj 字段设计

entitymgr 创建的实体对象通用字段：

```lua
local entity = {
    type_name = "role",          -- 实体类型名
    id = 12345,                  -- 实体 ID
    data = <ORM document>,       -- 持久化数据
    modules = {},                -- 子模块实例 (由框架自动填充)
    entity_mgr = <ref>,          -- entitymgr 反向引用
    fd = nil,                    -- 客户端 fd (client_enabled 类型)
}
```

同时根据 `id_field` 配置自动设置别名，便于业务代码使用习惯字段名：

```lua
entity[type_config.id_field] = entity_id  -- entity.rid / entity.gid / etc.
```

模块实例通过 `entity.modules.<name>` 访问，例如 `entity.modules.bag:add_item(...)`。

---

## 其他实体通过 entity_router 与角色交互

迁移后，其他实体可以直接与角色通信：

```lua
-- 公会给角色发奖励（角色可能离线）
entity_router.reliable_send("role", rid, "receive_guild_reward", {
    guild_id = gid,
    item_id = 1001,
    count = 10,
})

-- 场景通知角色位置更新
entity_router.send("role", rid, "on_position_update", { x = 100, y = 200 })

-- 同步查询角色在线状态
local info = entity_router.call("role", rid, "get_online_info")
```

---

## 迁移步骤（推荐顺序）

### 阶段 1：Entity 系统核心实现
完成 `entity_system_design.md` 中的所有新文件。

### 阶段 2：客户端扩展
1. 实现 `lualib/entity/client_ext.lua`
2. 修改 `service/entity_agent.lua` 添加 `client_enabled` 支持
3. 修改 `lualib/entity/entitymgr.lua` 添加客户端实体的卸载策略

### 阶段 3：Role Handler
1. 创建 `lualib/entity_handler/role.lua`
2. 在 `etc/nodes/common.app.lua` 中配置 `entity_types.role`
3. 在 `etc/nodes/role1.app.lua`、`role2.app.lua` 中添加 `entity_host = { "role" }`

### 阶段 4：登录流程切换
1. 修改 `app/role/login/login_request.lua`：使用 entity_router 替代 roleagent_api
2. 修改 `app/role/watchdog.lua`：创建 entity_agentmgr 替代 roleagentmgr
3. 修改 `tools/gen_roleagent_modules.lua`：调整输出以适配新的注册方式

### 阶段 5：清理旧代码
确认一切正常后删除：
- `app/role/roleagentmgr.lua`
- `app/role/roleagent/main.lua`
- `app/role/roleagent/rolemgr.lua`
- `app/role/roleagent/client.lua`
- `app/role/roleagent/global.lua`
- `app/role/lualib/roleagent_api.lua`
- `lualib/rolenode_api.lua`

保留并迁移到重构后路径（见 `directory_restructure.md`，`app/` → `example/nodes/`）：
- `example/nodes/role/modules/role/` — role 子模块（重构签名后）
- `example/nodes/role/modules/bag/` — bag 子模块（重构签名后）
- `example/nodes/role/modules/mail/` — mail 子模块（重构签名后）
- `example/nodes/role/login/` — 登录流程（已修改）
- `example/nodes/role/watchdog.lua` — fd 管理（已修改）

删除：
- `app/role/roleagent/modules/init.lua` — 自动生成文件，entity 系统自动发现替代
- `tools/gen_roleagent_modules.lua` — 代码生成器，不再需要

---

## 新增/修改文件汇总

### 新增

| 文件 | 说明 |
|------|------|
| `lualib/entity/client_ext.lua` | 客户端连接扩展（fd 管理 + sproto 分发） |
| `example/lualib/entity_handler/role.lua` | Role entity handler（服务端命令 + 生命周期，游戏层文件） |

### 修改

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `service/entity_agent.lua` | 中 | 添加 `client_enabled` 支持：bind_client、disconnect 命令 |
| `lualib/entity/entitymgr.lua` | 小 | 客户端实体的卸载定时器策略；自动初始化模块数据 |
| `app/role/login/login_request.lua` | 小 | `roleagent_api` → `entity_router` |
| `app/role/watchdog.lua` | 小 | `roleagentmgr` → `entity_agentmgr` |
| `app/role/roleagent/modules/role/request.lua` | 小 | 签名重构：`(request, fd, ctx)` |
| `app/role/roleagent/modules/bag/init.lua` | 小 | 构造函数重构：`new(entity, data)` |
| `app/role/roleagent/modules/bag/request.lua` | 小 | 签名重构 |
| `app/role/roleagent/modules/mail/init.lua` | 小 | 构造函数重构 |
| `app/role/roleagent/modules/mail/request.lua` | 小 | 签名重构 |
| `etc/nodes/common.app.lua` | 小 | 添加 `entity_types.role` 配置 |
| `etc/nodes/role1.app.lua` | 小 | 添加 `entity_host` |
| `etc/nodes/role2.app.lua` | 小 | 添加 `entity_host` |


### 删除

| 文件 | 说明 |
|------|------|
| `app/role/roleagentmgr.lua` | 被 entity_agentmgr 替代 |
| `app/role/roleagent/main.lua` | 被 entity_agent + handler 替代 |
| `app/role/roleagent/rolemgr.lua` | 被 entitymgr 替代 |
| `app/role/roleagent/client.lua` | 被 client_ext 替代 |
| `app/role/roleagent/global.lua` | 不再需要 |
| `app/role/lualib/roleagent_api.lua` | 被 entity/types.lua 替代 |
| `lualib/rolenode_api.lua` | 被 entity/types.lua jchash 替代 |
| `app/role/roleagent/modules/init.lua` | 自动生成文件，entity 系统自动发现替代 |
| `app/role/roleagent/modules/role/init.lua` | role 对象由 entity 对象替代，卸载由 entitymgr 管理 |
| `tools/gen_roleagent_modules.lua` | 代码生成器，不再需要 |

---

## 验证方案

1. **登录流程**：robot 连接 → 登录 → 收到 login_info 响应，验证完整流程走通
2. **跨节点登录**：配置双节点，robot 登录一个应该在 node2 的 rid，验证返回 `NOT_THIS_NODE` 并重连到正确节点
3. **断线重连**：robot 断线 → 在 `unload_delay` 内重连 → 验证角色仍在内存中
4. **角色卸载**：robot 断线 → 等待超过 `unload_delay` → 验证角色从内存卸载、数据已存盘
5. **跨实体通信**：通过 `entity_router.call("role", rid, "get_online_info")` 从另一个服务查询角色信息
6. **可靠消息**：`entity_router.reliable_send("role", rid, ...)` → 角色离线 → 角色登录 → 验证消息被处理
7. **sproto 协议**：发送 `role.login_info`、`bag.*` 等请求，验证 sproto 分发链路正常
8. **GM 命令**：`get_online_count` 等 GM 命令通过 entity_agentmgr 正常工作
9. **分布式锁**：双节点同时尝试加载同一角色，验证只有一个成功

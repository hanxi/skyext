# 通用实体系统

> **状态：已实现。** 核心组件（types / router / entitymgr / reliable_msg / client_ext / entity_agent / entity_agentmgr）均已合入主线。`role` 类型已通过 entity 系统运行——`example/nodes/role/watchdog.lua` 直接创建 `entity_agentmgr("role")`，旧版 roleagent / rolemgr 已移除。登录流程中变量名 `roleagentmgr` 是历史命名，实际指向 `entity_agentmgr` 服务。

## 概述

原先 `roleagent` 系统与 role 实体强耦合。若要支持公会、场景、怪物等其他实体，需要为每种类型复制一整套 agent/agentmgr/api 代码。entity 系统将此架构泛化：新增实体类型需配置节点、业务数据库与 schema，并提供 handler；随后可复用生命周期管理和消息路由等基础组件。

**核心能力：**
- Entity ID 稳定不变（snowflake ID）
- 路由跟随服务发现的存活节点（rendezvous hashing），节点进出只迁移它自己那一份实体
- 支持 `call`（同步）、`send`（异步）、`reliable_send`（持久化消息，实体加载时重试投递）
- 可选客户端连接绑定（`client_enabled`）

---

## 架构总览

```
任意 Service                    entity_agent:role:1 (skynet service)
     |                                  |
     | router.call("role", rid, cmd)    |
     |--------------------------------->| entity_call(rid, cmd, ...)
     |                                  |   -> entitymgr.with_entity(rid, handler)
     |  (local: skynet.call)            |   -> 按 ID 串行执行并检查租约
     |  (remote: cluster.call)          |
     |<---------------------------------| return result
```

**组件一览：**

| 文件 | 职责 |
|------|------|
| `lualib/skyext/entity/types.lua` | 实体类型注册表，委托 placement 选节点，modulo 选 agent |
| `lualib/skyext/entity/placement.lua` | 实体放置：读服务发现的存活节点，用 rendezvous hashing 选节点 |
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
| distributed_lock | `lualib/skyext/distributed_lock.lua` | etcd 分布式锁，用于协调跨节点实体加载 |
| dbmgr | `lualib/skyext/dbmgr.lua` | MongoDB ORM 加载/存盘/卸载，含脏数据定时刷盘 |
| save_wheel | `lualib/skyext/save_wheel.lua` | 回存轮：所有缓存文档共用一个定时器轮转刷盘 |
| cluster_discovery | `lualib/skyext/cluster_discovery.lua` | 服务注册/发现 |
| id_generator | `lualib/skyext/id_generator.lua` | snowflake ID 生成（reliable_msg 消息 ID） |
| machine_id | `lualib/skyext/machine_id.lua` | snowflake 机器号槽位：启动时从 etcd 抢一个带租约的编号 |
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
- `types.calc_node(type_name, entity_id)` — 委托给 `placement.calc_node`，见下
- `types.calc_agent_index(type_name, entity_id)` — `entity_id % agent_count + 1`
- `types.format_agent_service_name(type_name, index)` — 如 `".entity_agent:role:1"`

### 1.1 placement.lua — 实体落在哪个节点

候选节点来自服务发现：`entity_agentmgr` 在本节点全部 agent 就绪后注册服务名 `entity:<type>`，
`cluster_discovery` 把该服务的存活节点推给每个订阅方。**服务发现是权威**，`entity_types[*].nodes`
只是服务发现尚未就绪时的兜底列表，扩缩容不需要改配置（两者都为空才抛错）。

选节点用 **rendezvous hashing（HRW）**，对每个 `(实体, 节点)` 算分取最大值：

- 节点进出只迁移它自己那一份实体，别的实体原地不动；节点回来时拿回的也正好是原来那一份。
  jchash 做不到这点——它的输入是桶下标，从列表中间摘掉一个节点会把几乎所有实体重排。
- 结果与候选列表顺序无关。存活集合是从哈希表遍历出来的，顺序本来就不定，依赖下标的算法在
  这里会让各节点算出不同的答案。

**跨节点交接**：路由搬家后实体可能还被上一个节点持有着 etcd 锁。`entity_agent` 在 `entity_call` /
`entity_send` / `bind_client` 拿不到锁且确认了持有者时，向持有者发一次 `unload_entity` 再重试。
**只重试一次**：两边成员视图短暂分歧时，无限重试会变成互相抢。安全性由分布式锁本身保证——
路由短暂分歧最多让请求失败，不会出现两个节点同时持有同一实体。

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
1. `types.calc_node()` 确定目标节点（存活节点 + HRW，见 1.1）
2. `types.calc_agent_index()` 确定 agent 索引，拼出 service name
3. 通过 `config.get("cluster_node_name")` 判断本节点
4. 本节点 → `skynet.call/send`；远程 → `cluster.call/send`

**reliable_send 流程：**
1. `reliable_msg.save()` 持久化到 MongoDB
2. 尝试 `send` 立即投递（`__deliver_reliable` 命令）
3. 即时 `send` 抛错时记录警告；已保存但未标记投递的消息会在实体加载时被拉取并重试（`save` 自身失败仍会抛错）

这不是 exactly-once 保证：ack 失败、进程中断等会导致消息重投。实体入口按 ID 串行化，即时通知只触发对已持久化 pending 消息的拉取；handler 成功后先保存实体，再确认消息。已加载实体投递失败时每 5 秒重试；缺少 handler 时保留 pending 并阻止本页后续消息，需根据日志中的消息标识补齐 handler，或核对业务状态后人工处理。**不能直接删除或确认未处理的消息来解除阻塞。**业务逻辑必须以 `msg_id` 幂等。

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
    handle = <包含 fence 和失效回调的租约句柄>,
    invalid = false,    -- 失去租约后隔离，不再接受请求
    unload_timer = nil,
    unload_retry = nil,  -- 卸载失败的独立重试定时器
    delivery_retry = nil,
}
```

**ensure_loaded(entity_id) 流程：**
1. 同一实体 ID 的加载、handler、消息投递、客户端请求及卸载经 `skynet.queue` 串行化；命中有效缓存后重置卸载定时器
2. 未命中 → `distributed_lock.try_lock(lock_key, node_name, expired_cb)`；例如锁键 `"entity/role/12345"`、持有者值 `"rolenode1"`，成功返回带 etcd create revision (`fence`) 的句柄
3. `dbmgr.load(..., handle)` 通过一次 Mongo `findAndModify` 原子认领 fencing token 并读取最新文档，旧持有者后续写入必须同时匹配 `_fence` 与 `_version`；首次创建文档依赖实体 ID 字段的 **唯一索引** 防止并发创建重复行（示例 `role.rid` 已配置），业务集合也必须配置。初始化模块和 handler 后异步处理 pending 消息，启动卸载定时器
4. 租约失效回调立即隔离实体并断开客户端；旧实体不能重获原锁继续执行，也不能清理脏缓存；锁竞争返回独立的 `"lock held"` 原因及持锁节点名

**unload(entity_id) 流程：**
1. 取消闲置卸载与消息重试定时器，标记 `unloading` 并拒绝新请求
2. `handler.on_unload(entity)` → `_call_modules_on_unload`（`mod:on_unload()`）；重试时跳过已成功的钩子
3. `dbmgr.unload()` 确认最后一次持久化并清除缓存 **之后** 才按 create revision 比较并解锁；卸载完成或中途失败时均断开仍绑定的客户端。保存或解锁失败时保留实体与句柄，并通过独立定时器以 5 秒为初始间隔退避重试（实体配置 `unload_retry_delay` 可覆盖初始秒数，最长 300 秒）。数据已落库但解锁失败时只重试解锁，不重复落库或执行钩子
4. 租约已失效时仅允许丢弃无脏数据的缓存，脏缓存隔离等待人工恢复，不得写库或覆盖新持有者的数据；已经落库的实体若租约失效可直接释放内存对象

**调用时序**：加载时模块先于 handler 初始化（先有数据再处理业务），卸载时 handler 先于模块清理（先完成业务再释放数据）。

**touch(entity_id)**：重置卸载定时器。若 `entity.fd` 存在（有客户端连接），跳过——有连接的实体不设卸载定时器。

### 4. reliable_msg.lua — 可靠消息

MongoDB `entity.entity_msg` 集合，文档结构：
```
{ msg_id, seq, target_type, target_id, cmd, args, status, create_time, delivered_time,
  attempts, last_error, last_attempt_time, dead_time, dead_reason,
  replay_time, discard_time, discard_operator }
```

`status`：`0` pending、`1` delivered、`2` dead（毒消息已隔离）、`3` discarded（死信被人工丢弃）。

另有计数器集合 `entity.entity_msg_seq`：`{ _id = "<target_type>:<target_id>", seq }`。

**函数：**
- `save(target_type, target_id, cmd, args)` — 先用 `findAndModify($inc + upsert + new)` 原子分配
  该目标维度的自增 `seq`，再 insert；返回 `msg_id, seq`。写库失败直接抛错，不会让调用方
  误以为已经持久化。
- `load_pending(target_type, target_id, opts)` — 查询 `{status=0}` **按 `seq` 升序**，
  用 `seq > last_seq` 的 keyset 方式分页（`opts = { page_size, max_count, after_seq }`），
  返回数组。不要按 `msg_id` 排序：`id_generator` 的本地缓存池用哈希表发放预取 ID，
  snowflake ID 的大小并不反映 save 的先后。
- `mark_delivered(msg_id)` — `findAndModify({ query = { msg_id, status = 0 }, update = { $set = ... } })`
  将 status 置 1 并记录 `delivered_time`；幂等，首次 ack 返回 `true`，重复 ack 返回 `false`，
  写库失败返回 `false, err`（消息保持 pending，下次加载重投）。
- `record_failure(msg_id, err)` — `$inc attempts` 并记录 `last_error`/`last_attempt_time`，
  返回自增后的 `attempts`；查询限定 pending，写失败返回 `nil, err`。
- `mark_dead(msg_id, reason)` / `replay(msg_id)` / `discard(msg_id, operator)` / `list_dead(opts)` —
  死信队列的状态迁移与查询，均按 `{ msg_id, status = <期望状态> }` 条件更新，天然幂等。
- `max_attempts()` — 投递次数上限，节点配置 `reliable_msg_max_attempts`，默认 5。

**毒消息隔离与死信队列：** 一条 handler 必然抛错的消息会永远卡在队首，把同一实体后面
所有消息一起拖住，并以重试间隔持续刷错误日志。因此 entitymgr 区分两类投递失败：

| 失败类型 | 例子 | 处理 |
| --- | --- | --- |
| 消息级（`message_fault`） | 没有对应 handler、handler 抛错 | `record_failure` 计数，达到 `max_attempts()` 后 `mark_dead` 移入死信队列，队列继续往下走 |
| 环境级 | 租约失效、实体落库失败、ack 写库失败 | 不计数，整批投递停下来等重试定时器 |

把环境级失败计进去会让一次数据库抖动把正常消息误判成毒消息，所以这条边界是硬的。
未达上限时毒消息仍然卡在队首（消息之间可能有先后依赖，不能为了让队列往前走就跳过一条
还可能成功的消息）；隔离掉一条之后立刻 fork 一轮新的投递，让被它挡住的消息尽快跟上。

死信通过 `service/entity_dlq.lua`（由 entity_agentmgr 用 `uniqueservice` 按节点拉起）
暴露 GM 指令：

| 指令 | 参数 | 说明 |
| --- | --- | --- |
| `dlq_list` | `target_type` / `target_id` / `limit`（均可选） | 按入列时间列出死信；不返回 `args`，那是业务负载 |
| `dlq_replay` | `msg_id` | 状态回到 pending、`attempts` 清零，并唤醒目标实体 |
| `dlq_discard` | `msg_id` / `operator`（可选） | 置为 discarded，文档保留便于事后追查 |

死信队列是集群共享的一份 Mongo 数据，所以 `entity_dlq` 按节点单例而不是按实体类型注册：
GM 指令会在所有注册该指令的服务上执行，每类型注册一次会把一次查询变成 N 次。

**语义：** at-least-once。handler 执行成功之后才 ack；handler 抛错、节点宕机或 ack 写库失败时
消息保持 pending；已加载实体定时重试，重新加载时也会重投，因此**业务 handler 必须幂等**，
可用 `msg_id` 作为去重键。确认发生在实体状态成功持久化之后。`seq` 在计数器更新和消息 insert 之间并非事务性发布：并发生产者若在分配较小序号后延迟插入，后来的消息可能先被看到并处理。当前保证“对已落库 pending 消息按 seq 排序”，**不保证跨节点并发生产者的严格全序投递**；需要该语义时应引入 Mongo 事务或持久发布水位。

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
- `unbind_kick(fd, expected_entity)` — 仅在 fd 仍绑定预期实体时解绑并通知 gate 踢掉连接，避免异步卸载断开已重新绑定的 fd
- `get_entity(fd)` / `get_obj(fd)` — 按 fd 查找 entity；后者仅返回有效租约的 `{ entity = entity }` 上下文
- `with_request(fd, callback)` — 在该实体的串行化门内校验连接和租约；返回 `true, ...` 表示请求已执行，`false, reason` 表示连接解绑、实体失效等原因而未执行
- `reject_client(fd, reason)` — 带 session 的请求被拒且协议 response 没有 `errcode`/`code` 字段时，断开连接而非让客户端等待超时；有可编码的错误码字段时直接回错误响应。无 session 的单向通知只记日志

**客户端重连逻辑**（在 `entity_agent.lua` 的 `CMD.bind_client` 中实现）：
1. 尝试在本节点加载 entity（`try_ensure_loaded`）
2. 若 entity 被其他节点锁定，从独立的 owner 返回值取得节点名，经 cluster 请求持锁节点执行 `unload_entity`；对方必须先保存再解锁
3. 对方确认卸载后，在本节点重新加载并认领更高 fencing token
4. 已有旧 fd 连接时先 `unbind_kick` 踢掉旧连接
5. 绑定新 fd，通知 watchdog forward 后续消息

### 6. entity_agent.lua — 通用实体 agent

参数：`skynet.newservice("entity_agent", type_name, agent_index)`

启动时注册服务名（如 `.entity_agent:role:1`），若 `client_enabled` 则加载 client_ext。

**CMD 表：**
- `CMD.entity_call(entity_id, cmd, ...)` — 在 `with_entity` 门内加载、检查租约并调用 handler
- `CMD.entity_send(entity_id, cmd, ...)` — 同上但无返回值
- `CMD.__deliver_reliable(entity_id)` — 即时唤醒 pending 队列，从 Mongo 按 seq 拉取，持久化实体状态后再 ack
- `CMD.unload_entity(entity_id)` — 强制卸载（供重连流程跨节点调用）
- `CMD.bind_client(entity_id, fd)` — 客户端绑定（含重连逻辑，见上节）
- `CMD.disconnect(fd)` — 客户端断开，触发 unbind + handler 回调
- `CMD.start(conf)` — 初始化：加载数据模块和 sproto 协议、`require` handler、创建 entitymgr

Handler 通过 `require("entity_handler." .. type_name)` 加载。handler 是游戏层代码，放在 `example/lualib/entity_handler/`，Lua `require` 搜索路径自然优先命中游戏层。

### 7. entity_agentmgr.lua — agent 管理器

参数：`skynet.newservice("entity_agentmgr", type_name)`

启动流程：
1. `skynet.start` 注册命令，等待 watchdog 调用 `CMD.start({watchdog = ...})`
2. 读取 `agent_count`，调用 `discover_modules(modules_path, start_name)` 通过 luafilesystem 扫描模块目录
3. 顺序创建并启动 N 个 entity_agent，全部就绪后注册 cluster_discovery（`"entity:" .. type_name`）
4. watchdog 等 agent 管理器 ready 后才打开 gate 端口

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
                { "target_type", "target_id", "status", "seq", background = true },
                { "msg_id", unique = true, background = true },
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
| `lualib/skyext/entity/types.lua` | 实体类型注册与路由入口 |
| `lualib/skyext/entity/placement.lua` | 存活节点发现与 HRW 选节点 |
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

- per-target `seq` 分配与消息 insert 未使用多文档事务：单目标并发发送不保证跨节点严格全序投递，详见上文。
- `persistence.integration.test.lua` 已用真实 MongoDB/etcd 验证两个独立锁/DB 实例的租约撤销、fence 接管和旧 token 写入被拒绝；仍需部署多进程节点交接、网络分区和真实客户端重连的故障注入测试。
- 租约失效后如 ORM 缓存仍有未确认的修改，会隔离并保留脏缓存，须制定人工恢复/对账流程，不能自动丢弃或直接由后继覆盖。schema 热更的旧模块缓存与活跃对象迁移也尚未验证（见 `docs/guide/hotfix.md`）。

---

## 验证方法

1. **启动测试**：配置实体类型，启动 entity_agentmgr，验证 N 个 entity_agent 正常注册到 cluster_discovery
2. **路由测试**：通过 `router.call("role", rid, "get_online_info")` 验证消息路由到正确 agent
3. **路由稳定性**：重启节点，同一 entity_id 路由到同一节点
4. **reliable_send**：发送消息 → 验证 MongoDB 有记录 → 加载 entity → 验证消息被处理且标记 delivered
5. **分布式锁**：两节点同时 load 同一 entity，仅一个成功
6. **卸载**：entity 空闲 `unload_delay` 秒后自动卸载，数据已存盘
7. **客户端重连**：客户端断线后重连到另一节点，旧节点 entity 被卸载，新节点正常加载并绑定 fd

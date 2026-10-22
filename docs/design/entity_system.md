# 通用实体系统

> **状态：已实现。** 核心组件（types / router / entitymgr / reliable_msg / session / entity_agent / entity_agentmgr）均已合入主线。`role` 类型已通过 entity 系统运行——`example/nodes/role/main.lua` 直接 `newservice("entity_agentmgr", "role")` 并 `call(mgr, "lua", "start")`，旧版 roleagent / rolemgr / watchdog 已移除。客户端接入改为**会话层**（`skyext.entity.session` + `service/gate_tcp.lua`）：连接落在 gate 上，实体只持有 `entity.session = { gate_node, fd, key }`，详见[独立网关层设计](../plan/architecture_refactor.md#四独立网关层)。

## 概述

原先 `roleagent` 系统与 role 实体强耦合。若要支持公会、场景、怪物等其他实体，需要为每种类型复制一整套 agent/agentmgr/api 代码。entity 系统将此架构泛化：新增实体类型需配置节点、业务数据库与 schema，并提供 handler；随后可复用生命周期管理和消息路由等基础组件。

**核心能力：**
- Entity ID 稳定不变（snowflake ID）
- 路由跟随服务发现的存活节点（rendezvous hashing），节点进出只迁移它自己那一份实体
- 支持 `call`（同步）、`send`（异步）、`reliable_send`（持久化消息，实体加载时重试投递）
- 可选客户端会话绑定（`client_enabled`）：连接落在 gate 上，实体经会话键 `"<gate_node>/<fd>"` 收上行、发下行

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
| `lualib/skyext/entity/types.lua` | 实体类型注册表，委托 placement 选节点，打散 ID 后取模选 agent |
| `lualib/skyext/entity/placement.lua` | 实体放置：读服务发现的存活节点，用 rendezvous hashing 选节点 |
| `lualib/skyext/entity/router.lua` | 公共 API：call / send / reliable_send，自动路由到正确节点 |
| `lualib/skyext/entity/entitymgr.lua` | 单 agent 内实体生命周期（加载/卸载/缓存），复用 dbmgr + distributed_lock |
| `lualib/skyext/entity/reliable_msg.lua` | 可靠消息持久化（MongoDB），加载时投递 pending 消息 |
| `lualib/skyext/entity/session.lua` | 实体侧客户端会话：会话键 `"<gate_node>/<fd>"` 的绑定/解绑、上行入队、下行推送，仅 `client_enabled` 类型启用 |
| `service/gate_tcp.lua` | gate 服务（本地名 `.gate_tcp`）：基于 gateserver 监听 TCP、按 2 字节长度拆包、维护 `fd -> {owner_node, owner_service}`，未绑定时交登录服务、绑定后原样转发给实体所在节点 |
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
        auto_create = false,        -- 按 ID 加载时文档不存在是否新建，默认不建
        nodes = { "rolenode1", "rolenode2" },  -- 兜底节点列表，服务发现不可用时才用
        client_enabled = true,      -- 启用客户端会话（gate 连接、sproto 协议分发）
                                    -- 有会话时不启动卸载定时器
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
        auto_create = true,         -- 公会由业务直接按新 ID 创建时打开
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
- `types.calc_agent_index(type_name, entity_id)` — `placement.hash(entity_id) % agent_count + 1`。
  先打散再取模：snowflake ID 的低位是每秒归零的序号，直接取模会让低频发出的 ID 全挤进第一个 agent

**常驻实体与预加载**（全局单例用）：排行榜、公会管理器这类"每个 game 只有一份、挂了要能接管"的东西直接做成实体，
不另造选主机制——单活、持久化、故障接管、停服卸载都是现成的。类型配置上多两项：

- `resident = true`：不进闲置卸载计时，只在停服、失租时离开内存。
- `preload = { "rank:game1", 42, ... }`：要主动加载的实体，字符串经 `types.key_id` 换算成 ID，整数原样使用。
  `entity_agentmgr` 就绪后加载 HRW 落在本节点的那几个，之后每 3 秒再对一遍：持有者停服或崩溃、锁释放后，
  新的目标节点在下一轮把它接过来。锁还在别人手里时加载失败是正常的（粘性），不打 warn。

**作用域实体**：配置 `scope = "game" | "zone" | "global" | "server"` 的类型，每个作用域取值一份。实体 ID 由
`types.scoped_id(type, value)`（即 `key_id(type .. ":" .. scope .. ":" .. value)`）算出，`preload_ids` 按区服目录
（`skyext.realm.scope_values(scope)`）生成，配合每 3 秒一轮的预加载，开服后新取值的那一份自动出现。
访问用 `router.scoped_call / scoped_send(type, value, ...)`。`scope` 可以和 `preload` 同时配，两者的 ID 合并。

单例实体一般同时开 `auto_create`（第一次激活时文档还不存在），集合要给 ID 字段建唯一索引。数据量大的单例
（完整排行、全部公会）不要整份放进一个文档，handler 自己管理独立集合，实体系统只保证同一时刻只有它在写。

**实体定时器**：`entity:every(name, sec, fn)`、`entity:after(name, sec, fn)`、`entity:cancel_timer(name)`。
回调经 `with_loaded_entity` 在实体的串行队列里执行，实体卸载、失租后自动停止，同名定时器会替换旧的；
回调出错只记日志，重复定时器照常继续。定时器**不会延长实体寿命**（不重置闲置卸载计时），常驻实体以外的
实体闲置到期照样卸载。

**`auto_create`**：实体按 ID 寻址，传错一个 ID 不该凭空造出一份文档。默认关闭，此时文档不存在
`ensure_loaded` 返回 `false, "not found"`，`bind_session` 返回 `ENTITY_NOT_FOUND`。角色文档由 Account
建角时创建，所以示例的 `role` 不开；由业务直接拿新 ID 调用实体来创建的类型才打开。
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

**粘性路由**：节点进出后实体的目标节点会变，但已经加载的实体还留在上一个节点上，锁也在它手里。
这时 `entity_agent` 不把实体要过来，而是把请求**转给持锁节点执行**：

- `entity_call` / `entity_send` 转发为持锁节点上的 `entity_call_loaded`，`__deliver_reliable` 转发为
  `deliver_reliable_loaded`。持锁节点只处理已经加载的实体，绝不为转发请求加载。
- 持锁节点回 `NOT_LOADED`（实体刚好卸掉了）时，什么都没执行，回到本地再试一次，此时锁多半已经空出来。
  只试这一次，两个节点不会把一个请求来回踢。
- 转发本身抛错时**不重试**：分不清是没送到，还是对方的 handler 执行到一半出错了，重试可能让副作用发生两次。
  `entity_call` 把错误原样抛给调用方。
- 持锁的是本节点名，说明是上一次进程留下的租约还没过期，不转发，等租约过期。

为什么不直接让持锁节点卸载：卸载会把在线玩家踢下线，扩一次容就掉一批人；两边成员视图短暂不一致时，
实体还会被来回搬。粘性路由下，实体在旧节点自然卸载（玩家下线、闲置超时、停服）之后，下一次加载才落到新节点。

**登录交接**：只有客户端重新登录（`bind_session`）时才把实体要过来——向持锁节点发一次 `unload_entity`，
对方卸载（顺带踢掉旧连接）后本地再加载。同样只请求一次。安全性始终由分布式锁保证：路由短暂分歧最多
让请求失败，不会出现两个节点同时持有同一实体。

### 2. router.lua — 消息路由 API

```lua
local entity_router = require "skyext.entity.router"

-- 同步调用：返回 true, handler 的返回值...，或 false, reason（实体不可用，handler 没执行）
local ok, info = entity_router.call("role", rid, "get_online_info")

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

**目标实体不存在**：类型没开 `auto_create`、库里也没有这份文档时，投递拿到 `"not found"`，这些消息永远投不出去，
又不会被 TTL 清掉（TTL 只清已投递的）。`deliver_pending` 会把该实体的 pending 消息整批移进死信队列
（`dead_reason = "entity not found"`），文档后来补上了可以用 `dlq_replay` 重放。

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
    session = nil,      -- 客户端会话 { gate_node, fd, key }（仅 client_enabled 类型）
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
3. `dbmgr.load(..., handle, { create = auto_create })` 通过一次 Mongo `findAndModify` 原子认领 fencing token 并读取最新文档，旧持有者后续写入必须同时匹配 `_fence` 与 `_version`；文档不存在且类型没开 `auto_create` 时释放锁并返回 `"not found"`。开了 `auto_create` 的类型首次创建文档依赖实体 ID 字段的 **唯一索引** 防止并发创建重复行，业务集合必须配置。停服期间（见下）不再加载新实体，返回 `"node shutting down"`。初始化模块和 handler 后异步处理 pending 消息，启动卸载定时器
4. 租约失效回调立即隔离实体并断开客户端；旧实体不能重获原锁继续执行；锁竞争返回独立的 `"lock held"` 原因及持锁节点名

**unload(entity_id) 流程：**
1. 取消闲置卸载与消息重试定时器，标记 `unloading` 并拒绝新请求
2. `handler.on_unload(entity)` → `_call_modules_on_unload`（`mod:on_unload()`）；重试时跳过已成功的钩子
3. `dbmgr.unload()` 确认最后一次持久化并清除缓存 **之后** 才按 create revision 比较并解锁；卸载完成或中途失败时均断开仍绑定的客户端。保存或解锁失败时保留实体与句柄，并通过独立定时器以 5 秒为初始间隔退避重试（实体配置 `unload_retry_delay` 可覆盖初始秒数，最长 300 秒）。数据已落库但解锁失败时只重试解锁，不重复落库或执行钩子
4. 租约已失效时，干净缓存（库里已是最新）直接丢弃，实体出内存；已经落库的实体若租约失效可直接释放内存对象
5. 租约已失效**且缓存是脏的**走失租恢复（见下）。不论恢复成功与否，实体最终都必须离开内存——留在 `entities` 里既不服务请求，又让后续 `ensure_loaded` 恒定失败

**停服（`unload_all`）：**

`entity_agentmgr` 的 `shutdown` 先从服务发现注销 `entity:<type>`，路由随之移到其他节点；再让每个 agent
执行 `unload_all`：置 `closing` 拒绝加载新实体，以有限并发卸载全部已加载实体（落库、释放锁、断开客户端），
返回剩余数量；卸干净的 agent 随即停止加锁（锁键真正从 etcd 消失是 `node_shutdown` 撤销节点租约时，租约是节点级的，别的服务还挂在上面）。有实体卸不掉时每秒再来一轮，直到卸干净或超时，返回剩余实体数。
整个节点的停服由引擎服务 `service/node_shutdown.lua`（GM 命令 `shutdown`）驱动：它按 `.entity_agentmgr:<type>`
本地名找到本节点起了的实体类型，前后分别回调游戏层挂的 `stop_accepting` / `release` 钩子；卸不掉就不退出，
那些实体还有没落库的改动。

**失租恢复流程（`_recover_dirty` → `dbmgr.recover`）：**

租约断了但内存里还有没落库的改动时，这份改动能不能写回去，唯一的判据是 `_version`：

1. `dbmgr.quarantine` 先把条目从回存轮上摘掉止血——租约已经没了，`save_doc` 必然拒绝写入，留在轮上只会让每一轮刷一条 `refusing save without lease`
2. 重新 `try_lock` 拿一把新租约（新 fence）
3. `dbmgr.recover` 用新 fence 原子认领文档，然后比较库里的 `_version` 和缓存里的 `_version`：
   - **相等** → 失租期间没有人真的写过这个文档（接管者可能只是把实体加载起来又原样卸载），这份改动仍然是库里状态的延续，在新 fence 下落库，返回 `true`
   - **不等** → 改动已经基于一份过时的快照，写回去就是拿旧数据盖新数据。返回 `false, "superseded"`，记一条 error，清掉缓存；调用方可以安全地把实体忘掉
4. 抢不到锁或写入失败时保留缓存并退避重试。关键实现细节：`recover` 只把新 handle 传给这一次写入，**不改 `cache.handle`**——写失败时缓存要原样留着，下一轮重试仍然按旧 handle 找得到它
5. 重试次数达到 `DIRTY_RECOVERY_MAX_ATTEMPTS`（8 次，退避累计约 15 分钟，远超 30 秒的租约 TTL）仍拿不到锁，说明实体已被别的节点接管且对方正基于库里的数据在工作。此时 `dbmgr.discard` 强行丢弃改动并记 error。这是一次确定的数据回退，但代价小于让实体永久占着内存且永远无法再加载

新 fence 认领只能挡住旧持有者的写入，挡不住「接管者已经完整写过一轮」这件事——所以 `_version` 比较是不可省的第二道闸门。

**调用时序**：加载时模块先于 handler 初始化（先有数据再处理业务），卸载时 handler 先于模块清理（先完成业务再释放数据）。

**touch(entity_id)**：重置卸载定时器。若 `entity.session` 存在（有客户端会话），跳过——有会话的实体不设卸载定时器。

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

### 5. session.lua — 客户端会话管理

仅在 `client_enabled = true` 的实体类型中由 entity_agent 加载（`CMD.start` 里 `session.init(entitymgr)`）。
连接落在 gate 服务（`service/gate_tcp.lua`，本地名 `.gate_tcp`）上，实体只持有一个**会话键**
`key = "<gate_node>/<fd>"`（全集群唯一），模块内维护 `g_sessions: key -> entity`。回包和推送都发给会话
所在的 gate：gate 与实体同进程走本地 `skynet.send/call`，否则走 `cluster.send/call`（由 `self_node()`
即 `config.get("cluster_node_name")` 判断）。

**核心函数：**
- `key(gate_node, fd)` — 拼会话键 `"<gate_node>/<fd>"`
- `init(entitymgr)` — 注入 entitymgr 引用（供 unbind 触发 touch），并把 `sproto_api` 的发送端
  `set_sender` 换成"按会话键找到 gate 再 push 字节"
- `bind(gate_node, fd, entity, owner_service)` — 先 `gate_call(gate_node, "bind", fd, self_node(), owner_service)`
  让 gate 把这条连接之后的包转给 `owner_service`；gate 那边会话已断开时返回 `false`。成功则记 `g_sessions[key]`、
  设 `entity.session = { gate_node, fd, key }`、取消卸载定时器
- `unbind(key)` — 解绑，清 `entity.session`，调用 `entitymgr:touch` 重启卸载定时器
- `kick(key)` — 断开客户端连接：从 key 解析出 `gate_node`/`fd`，`gate_send(gate_node, "kick", fd)`。
  解绑本身交给 gate 的断开通知（`session_closed`），这样 `on_unbind_client` 照常执行
- `unbind_kick(key, expected_entity)` — 仅在 `g_sessions[key]` 仍是 `expected_entity` 时才 unbind+kick，
  防止误踢已经换绑的新会话；**幂等**：会话已解绑（`entity.session` 被清）后再调返回 `false`，停服/失租
  路径对同一实体调两次也只踢一次
- `get_entity(key)` / `get_obj(key)` — 按会话键查 entity；后者仅在当前 entity 仍持有效租约时返回 `{ entity = entity }`
- `with_request(key, f)` — 在该会话所绑实体的串行队列（`with_loaded_entity`）里执行 `f`；排队期间会话可能已
  解绑或换绑，届时返回 `false, reason`（`f` 不执行）。返回 `true, ...` 表示已执行
- `reject_client(key, reason)` — 请求被拒且错误码无法通过协议回给客户端时的兜底：`kick(key)` 断开连接，让客户端立刻失败重连
- `push(entity, name, msg)` — 给实体自己的客户端推一条消息（`sproto_api.notify(entity.session.key, name, msg)`），不在线返回 `false`

**客户端登录/重连逻辑**（在 `entity_agent.lua` 的 `CMD.bind_session` 中实现）：
1. 尝试在本节点加载 entity（`try_ensure_loaded`）；文档不存在返回 `ENTITY_NOT_FOUND`
2. 若 entity 被其他节点锁定，从独立的 owner 返回值取得节点名，经 cluster 请求持锁节点执行 `unload_entity`；对方必须先保存再解锁。要不过来时返回 `IN_OTHER_NODE`
3. 对方确认卸载后，在本节点重新加载并认领更高 fencing token
4. 已有旧会话且会话键不同（同一角色在新连接上重登）时，先 `unbind_kick` 踢掉旧会话
5. `session.bind(gate_node, fd, entity, owner_service)` 绑定新会话；gate 已断开该连接时返回 `SESSION_CLOSED`
6. 调用 handler 的 `on_bind_client(entity, session_key)`

### 6. entity_agent.lua — 通用实体 agent

参数：`skynet.newservice("entity_agent", type_name, agent_index)`

启动时注册服务名（如 `.entity_agent:role:1`），若 `client_enabled` 则加载 `session`（`sproto_api.register_module(name, session, request)` 把会话层登记为各协议的连接管理模块）。

**CMD 表：**
- `CMD.entity_call(entity_id, cmd, ...)` — 在 `with_entity` 门内加载、检查租约并调用 handler，返回 `true, ...` 或 `false, reason`；锁在别的节点时转发（见 1.1 粘性路由）
- `CMD.entity_send(entity_id, cmd, ...)` — 同上但无返回值
- `CMD.entity_call_loaded(entity_id, cmd, ...)` — 转发入口，只用已加载的实体
- `CMD.__deliver_reliable(entity_id)` — 即时唤醒 pending 队列，从 Mongo 按 seq 拉取，持久化实体状态后再 ack；锁在别的节点时转发
- `CMD.deliver_reliable_loaded(entity_id)` — 转发入口，只投递给已加载的实体
- `CMD.activate(entity_id)` — 主动把实体加载进内存（`ensure_loaded`），返回是否成功；供预加载、 scoped 实体激活使用
- `CMD.unload_entity(entity_id)` — 强制卸载（供登录交接跨节点调用）
- `CMD.shutdown()` — 停服：拒绝新加载、卸载全部实体，返回剩余数量；卸干净后本服务不再加锁（节点租约由 `node_shutdown` 统一撤销）
- `CMD.bind_session(entity_id, gate_node, fd)` — 把 gate 上的一条会话绑到实体（含重登交接、踢旧会话，见上节）；由登录服务经 `router.bind_session` 调用，返回错误码
- `CMD.client_msg(gate_node, fd, data)` — gate 转来的上行字节：`sproto_api.dispatch_message(session.key(gate_node, fd), data)` 解码并分发到对应模块的 request handler
- `CMD.session_closed(gate_node, fd)` — gate 通知会话断开：在 `with_loaded_entity` 门内确认仍是当前会话后 `session.unbind`，触发 `on_unbind_client`；实体已失效时兜底解绑
- `CMD.start(conf)` — 初始化：加载数据模块和 sproto 协议、`require` handler、创建 entitymgr、`session.init(entitymgr)`

Handler 通过 `require("entity_handler." .. type_name)` 加载。handler 是游戏层代码，放在 `example/lualib/entity_handler/`，Lua `require` 搜索路径自然优先命中游戏层。

### 7. entity_agentmgr.lua — agent 管理器

参数：`skynet.newservice("entity_agentmgr", type_name)`

启动流程：
1. `skynet.start` 注册命令并用本地名 `.entity_agentmgr:<type>` 登记自己；节点主程序（如 `example/nodes/role/main.lua`）`newservice("entity_agentmgr", type)` 后 `call(mgr, "lua", "start")`
2. `CMD.start()` 幂等且并发安全：`g_ready` 时直接返回；`g_starting` 时等前一次结束并复用其结果；失败会把 `g_start_error` 粘住，后续 start 直接抛同一个错
3. `create_agents(agent_count)`：`discover_modules(modules_path, start_name)` 用 luafilesystem 扫描模块目录，顺序创建并启动 N 个 entity_agent
4. `pcall(uniqueservice, "entity_dlq")` 拉起死信队列服务（失败只记日志，不阻塞）
5. 全部 agent 就绪后 `cluster_discovery.register({ "entity:" .. type_name })` 向集群发布，置 `g_ready`
6. `start_preload()`：配了 `scope` 或 `preload` 的类型，加载 HRW 落在本节点的那些 ID，之后每 3 秒 reconcile 一轮（持有者停服/崩溃后由新目标节点接管）

停服编排靠 `.entity_agentmgr:<type>` 本地名找到本节点起了的实体类型。
`CMD.shutdown(timeout_sec)` 是停服入口：注销服务发现，再并行让各 agent 卸载，每秒重试直到卸干净或超时，返回剩余实体数（见「停服」）。

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

-- 统一签名: handler(request, conn, ctx)
-- request = sproto 解码后的请求数据
-- conn = 连接标识，即会话键 "<gate_node>/<fd>"（sproto_api 沿用了形参名 fd）
-- ctx = { entity = entity_obj }，由 session.get_obj(conn) 提供
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

-- 客户端会话回调（仅 client_enabled 类型，可选）
function M.on_bind_client(entity, session_key) end
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
| `lualib/skyext/entity/session.lua` | 实体侧客户端会话（会话键绑定/解绑、上行入队、下行推送） |
| `service/gate_tcp.lua` | gate 服务（`.gate_tcp`）：监听 TCP、拆包、会话表、上行转发/下行 push |
| `service/entity_agent.lua` | 通用实体 agent 服务 |
| `service/entity_agentmgr.lua` | agent 管理器 |

**游戏层（example）：**

| 文件 | 说明 |
|------|------|
| `example/lualib/entity_handler/example.lua` | 接入示例 handler |
| `example/lualib/entity_handler/role.lua` | 角色 handler（含客户端会话回调、recv_mail、kick） |
| `example/lualib/entity_handler/rank.lua` | 排行榜 handler（`scope = "game"` 的作用域实体） |
| `example/nodes/role/modules/bag/` | 角色背包模块（init + request） |
| `example/nodes/role/modules/role/` | 角色基础模块（request） |
| `example/nodes/role/modules/mail/` | 角色邮件模块（init + request） |
| `example/nodes/role/modules/rank/` | 排行榜上行协议模块（request） |
| `example/service/login/` | 登录服务（JWT、rid 归属、出生服校验，经 `router.bind_session` 绑定会话）；role 节点与独立网关节点共用 |
| `example/service/admin/` | 示例运营命令（发系统邮件等） |
| `example/nodes/gateway/main.lua` | 独立网关节点主程序（`start = "gateway"`）：`launcher_node()` + `launcher_gate()`，只接连接不承载实体 |

**修改过的现有文件：**

| 文件 | 修改内容 |
|------|----------|
| `example/etc/nodes/common.app.lua` | 添加 `entity_types` 配置和 `mongo_config.entity` |
| `lualib/skyext/errcode.lua` | 添加 `ENTITY_NOT_FOUND`(20) / `ENTITY_LOCK_FAILED`(21) / `ENTITY_LOAD_FAILED`(22) / `SESSION_CLOSED`(23)；`bind_session` 复用既有的 `IN_OTHER_NODE`(2) |

---

## 已知问题

- per-target `seq` 分配与消息 insert 未使用多文档事务：单目标并发发送不保证跨节点严格全序投递，详见上文。
- `persistence.integration.test.lua` 已用真实 MongoDB/etcd 验证两个独立节点租约/锁/DB 实例的租约撤销、fence 接管和旧 token 写入被拒绝；仍需部署多进程节点交接、网络分区和真实客户端重连的故障注入测试。
- 失租恢复在重试 8 次（约 15 分钟）后会丢弃脏改动，这是一次无人值守的数据回退。日志里的 `dirty entity changes discarded` 和 `dirty cache superseded while lease was lost` 都是 error 级，应当接到告警上做事后对账；目前没有把被丢弃的改动落盘留档的机制。
- schema 热更的旧模块缓存与活跃对象迁移尚未验证（见 `docs/guide/hotfix.md`）。

---

## 验证方法

1. **启动测试**：配置实体类型，启动 entity_agentmgr，验证 N 个 entity_agent 正常注册到 cluster_discovery
2. **路由测试**：通过 `router.call("role", rid, "get_online_info")` 验证消息路由到正确 agent
3. **路由稳定性**：重启节点，同一 entity_id 路由到同一节点
4. **reliable_send**：发送消息 → 验证 MongoDB 有记录 → 加载 entity → 验证消息被处理且标记 delivered
5. **分布式锁**：两节点同时 load 同一 entity，仅一个成功
6. **卸载**：entity 空闲 `unload_delay` 秒后自动卸载，数据已存盘
7. **客户端重连**：客户端断线后重连到另一个 gate，旧节点 entity 被卸载，新节点正常加载并 `bind_session` 绑定会话
8. **独立网关转发**：客户端连独立网关节点（`gate1`，端口 7052），登录经 `router.bind_session` 绑到实体所在 role 节点，上行/下行经 gate 跨节点转发（`logs/robot.log` 三个 robot 分别连 7012/7022/7052 全部跑通 login→bag→mail→rank）

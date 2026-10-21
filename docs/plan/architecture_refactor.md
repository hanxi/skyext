# 架构重构设计：逻辑服 + 共享基础设施

> **状态：分阶段实现中。** 阶段 1（常驻实体、实体定时器）、阶段 2（区服目录、作用域实体）、阶段 3（独立网关层、会话亲和转发、登录迁到 Gate、同进程部署）已实现，其余均为目标设计。
> 分层约定：通用机制放 skyext 框架层，具体玩法与产品取舍（名字规则、服务器列表、排行榜）放 example。现状以[架构概览](../overview.md)和代码为准。
>
> 已确认的方向：按"第三代"区服模型建设——服只是玩法标签，玩家数据放在共享集群里；引入独立网关层并保留同进程部署；允许为此重构现有基建，不考虑兼容。

## 目标

一个面向"以玩家数据为中心"游戏（SLG、卡牌、放置、休闲 MMO）的服务器框架，要同时满足：

1. **开服、合服是运营操作，不是工程操作**：开新服不加机器、不重启；合服不搬数据、不停机。
2. **跨服是常态**：跨服匹配、跨服组队、跨服战场、跨服排行，用的是和本服功能同一套机制，只是作用域更大。
3. **玩家数据只有一个家**：任何玩法都不复制可写的玩家数据。跨服活动持有的是引用和只读快照，结果靠可靠消息写回。
4. **逻辑节点可以随时重启**：发版、扩容、迁机器都不踢玩家。

## 总览

```
                 ┌──────────── 平台/SDK 登录（签发 JWT）
客户端 ─HTTP─> Account 节点：服务器列表、角色列表、建角
   │
   └─TCP/WS─> Gate 节点：会话、鉴权、上行转发、下行推送、频道
                  │  cluster
                  ▼
            Logic 节点池（role、rank、match、team… 各类实体，不按区服划分）
                  │
     ┌────────────┼──────────────┐
   MongoDB      etcd           区服目录（realm，存 etcd）
  玩家/实体数据  锁、服务发现   server→game→zone 映射，节点 watch 缓存
```

和现在相比，结构上的变化有三处：新增 **Gate 节点**；**区服目录**从静态配置变成运行时可改的数据；实体系统新增**作用域实体**和**临时实体**两种用法。

---

## 一、作用域模型

### 四层作用域

```
server ──> game ──> zone ──> global
 区服       逻辑服    战区      全服
```

| 层 | 含义 | 谁决定 |
|----|------|--------|
| server | 玩家选服时看到的区服，角色的**出生服**，终身不变 | 建角时选定 |
| game | 逻辑服：一起玩的那批人。排行榜、公会、世界聊天、经济系统以它为界 | 区服目录 `server → game`，合服就是改这个映射 |
| zone | 战区：若干 game 组成，跨服匹配、跨服战场、跨服排行以它为界 | 区服目录 `game → zone`，按开服时间、活跃度调整 |
| global | 全服：好友、私聊、全服公告 | — |

### 每个功能自己声明作用域

引擎不规定"玩家只能和同 game 的人交互"。每个全局功能在设计时选一层作用域，并由功能自己检查边界。业界惯例：**社交可以跨服，经济默认不跨服**。

| 功能 | 作用域 | 边界检查 |
|------|--------|----------|
| 排行榜、公会、世界聊天 | game | 天然隔离：按 game 各起一份实体 |
| 交易、拍卖、带附件的转赠 | game | 发起时检查双方同 game，防止一个服的通胀扩散 |
| 跨服匹配、跨服战场、跨服排行 | zone | 按 zone 各起一份实体 |
| 好友、私聊 | global | 不检查（通常要求先加好友） |
| 全服公告、全服邮件 | global | — |

### 区服目录（realm）

**现在**：`server2game` 写死在每个节点的配置文件里，开服、合服都要改配置、重启全部节点。

**改为**：区服目录存在 etcd（数据量小、天然支持 watch，且已经是依赖），由 GM/运营后台修改，所有节点 watch 并缓存：

```
/skyext/realm/server/s1   {"game":"game1","name":"一区","open_time":...,"status":"open"}
/skyext/realm/server/s3   {"game":"game2", ...}            -- 已合入 game2
/skyext/realm/game/game1  {"zone":"zone1"}
/skyext/realm/zone/zone1  {}
```

引擎模块 `skyext.realm` 提供查询和变更通知：

```lua
realm.server(server)               -- { game, name, tag, status, open_time }
realm.game_of(server)              -- "game1"
realm.zone_of(game)                -- "zone1"
realm.tag_of(server)               -- "S1"，跨服场景的服号
realm.scope_value("zone", server)  -- 出生服为 server 的角色属于哪个 zone
realm.scope_values("game")         -- 这一层的全部取值，开服后自动出现
realm.subscribe(fn)                -- 目录变化回调（开服、合服、调战区）
```

### 角色只记出生服，不记 game

**现在**：角色文档里存了 `server` 和 `game` 两个字段，合服要批量改所有角色文档。

**改为**：角色文档只存 `server`，`game` 每次用 `realm.game_of(role.server)` 实时算。**合服只改目录里的一条映射，不改任何玩家文档。**这是第三代模型的核心收益，代价是读 game 多一次内存查表。

### 重名

**现在**：建角没有同名检测（TODO）。

**改为**：名字在**出生服内唯一**（`(server, name)` 唯一索引的名字表）。合服、跨服时不会因此冲突；在跨服场景里显示为 `[S3]张三`（业界通行做法），不需要合服时强制改名。

---

## 二、作用域实体：一个作用域一份的全局功能

阶段 1 已经实现了常驻实体（`resident`、`preload`、实体定时器），现在要把它和区服目录接起来：

```lua
entity_types.rank = {
    db_name = "entity", db_coll = "rank", id_field = "rank_id",
    resident = true,
    auto_create = true,
    scope = "game",   -- 每个 game 一份；也可以是 "zone" / "global"
}
```

- **寻址**：`router.scoped_call("rank", "game1", "top", 10)`，实体 ID 由 `types.scoped_id(type, value)` 算出，任何节点直接算，不查表。
- **自动预加载**：配了 `scope` 的类型不用再手写 `preload` 列表，`entity_agentmgr` 按 `realm.games()`（或 zones）生成 ID 并订阅目录变化。**开新服时，新 game 的排行榜、公会管理器在几秒内自动出现在某个节点上。**
- **合服**：目录把 game3 并入 game2 后，引擎对每个 `scope = "game"` 的类型调用 handler 的 `on_merge(target_entity, source_id)`，比如把 game3 排行榜的条目并进 game2，再归档源实体。合服流程由 GM 命令 `realm_merge` 编排，过程中源 game 的作用域实体拒绝写入。

---

## 三、临时实体与"不唤醒"调用

跨服玩法里大量对象是短命的：队伍、匹配中的房间、一场战斗。它们需要"同一时刻只在一个地方"，但不需要（也不该）落库。

### 临时实体

```lua
entity_types.team = {
    persistent = false,   -- 只在内存，不读写 Mongo
    auto_create = true,
    unload_delay = 60,    -- 最后一个成员离开后多久销毁
}
```

- 仍然用 etcd 锁保证单活（两个节点不会各有一份同一个队伍）。
- 节点崩溃时临时实体直接丢失，由参与方超时处理（队伍解散、战斗判无效）。这和业界做法一致：跨服队伍、房间都不持久化。

### 不唤醒调用

**现在**：`router.call` 发给离线玩家会把他的整份数据从 Mongo 加载进来。查 100 个好友的在线状态就会加载 100 个离线角色。

**改为**：新增 `router.call_loaded` / `router.send_loaded`：只投递给当前已经加载的实体，没加载就返回 `false, "offline"`，绝不触发加载。粘性路由里已经有 `entity_call_loaded`，这里只是把它变成公开 API。在线状态、跨服邀请、队伍推送都用它。

---

## 四、独立网关层

### 现状的问题

客户端连接、gate、实体必须在同一个 role 节点上：逻辑节点不能无感重启；实体迟早要回到 HRW 节点，回去的方式只有下线重登；客户端要知道每个逻辑节点的地址。跨服玩法还会放大这个问题：队伍、战斗实体要给分散在各个节点上的玩家推消息。

### 方案

新增 **Gate 节点**，只管连接，不持有玩法状态：

```
客户端 ──> Gate：会话表 session -> { rid, server, owner_node, 已订阅频道 }
             │ 上行：按会话直接发给 owner_node（会话亲和，同一玩家天然保序）
             ▼
           Logic：role 实体持有 { gate_node, session_id }
             │ 下行：cluster.send(gate_node, "push", session_id, bytes)
```

- **登录**在 Gate 完成：校验 JWT、校验 rid 归属与出生服，调用 role 实体 `bind_session(rid, gate_node, session_id)`，记下实体所在的 `owner_node`。
- **协议**：Gate 只解包头，原样转发字节，由实体侧解码。协议热更不用动 Gate。
- **推送 API**：`session.push(entity, name, msg)` 给自己的客户端推；队伍、战斗这类实体给成员推送时，经成员的 role 实体转发（`router.send_loaded("role", rid, "push", ...)`）。
- **同进程部署**：小规模时 Gate 与 Logic 在一个进程里，代码路径相同，只是 cluster 调用退化为本地调用。
- **WebSocket**：继续由 goscon 在前面转 TCP，Gate 只做 TCP。

### 阶段 3 的实现方案

| 层 | 组件 | 职责 |
|----|------|------|
| 框架 | `service/session_gate.lua`（本地名 `.session_gate`） | 基于 skynet gateserver：监听 TCP、按 2 字节长度拆包、维护会话表 `fd -> { owner_node, owner_service }`。未绑定的会话把包交给登录服务；绑定后**原样**转发给实体所在节点（同节点 `skynet.send`，跨节点 `cluster.send`）。提供 `bind / push / kick`，挂停服钩子 `stop_accepting` |
| 框架 | `skyext.entity.session`（取代 `client_ext`） | 实体侧的会话：会话键 `"<gate_node>/<fd>"`，`bind / unbind / with_request / kick / push`；把 `sproto_api` 的发送端换成"发给会话所在的 gate" |
| 框架 | `entity_agent` | `bind_session(id, gate_node, fd)`（取代 `bind_client`，含重登交接、踢旧会话）、`client_msg`（上行解码分发）、`session_closed`（取代 `disconnect`）；不再需要 watchdog |
| 框架 | `router.bind_session(type, id, gate_node, fd)` | 登录服务调用：按 HRW 找到实体节点并绑定，**不再有 `NOT_THIS_NODE` 重定向** |
| 框架 | `sproto_api` | 发送端可替换（`set_sender`）；`dispatch_message(conn, bytes)` 解码一个上行包；`push(conn, name, msg)` 下行推送 |
| 示例 | `example/service/login/` | 登录协议（JWT、rid 归属、出生服校验），role 节点与独立 gate 节点共用 |
| 示例 | 节点 | role 节点 = gate + 登录 + 实体（同进程部署）；新增独立网关节点（目录 `nodes/gateway/`、`start = "gateway"`，实例 `gate1`）= 只有 gate + 登录（独立部署）。客户端连任意一个 gate 都能进游戏。**节点目录名不能叫 `gate`**：`nodes/?/main.lua` 是通配搜索路径，叫 `gate` 会劫持 skynet 自带的 `gate` 服务（clusterd 监听时 `newservice("gate")` 会误起网关节点主程序），故取名 `gateway` |

客户端地址：生产环境客户端连的是 gate 前面的负载均衡或 goscon，不需要知道具体节点；`/roles` 不再返回 `rolenode`。

### 无感迁移（逻辑节点滚动发版）

实体要离开当前节点时（停服、交接），不再踢客户端：

1. 实体卸载前通知 Gate `migrate(session_id)`；Gate 暂停这个会话的上行，把收到的包缓存起来。
2. 实体落库、释放锁。
3. Gate 重新调用 `bind_session`，实体在 HRW 指向的新节点上加载。
4. Gate 按顺序回放缓存的包，恢复转发。

玩家只感到一次几十到几百毫秒的卡顿，不会掉线重登。停服编排（`node_shutdown`）的卸载阶段改为"迁移会话后卸载"。

**代价**：每条客户端消息多一次节点间跳转（同机房约 0.1–0.5ms）；Gate 节点崩溃会断开它上面的连接，但不丢任何玩家数据。

---

## 五、频道与广播

广播的对象是在线连接，连接在 Gate 上，所以频道也挂在 Gate 层。频道名就是作用域键：

| 频道 | 用途 |
|------|------|
| `game:game1` | 本服世界聊天、本服公告 |
| `zone:zone1` | 战区公告、跨服活动开启通知 |
| `global` | 全服公告 |
| `guild:<id>`、`team:<id>` | 公会、队伍频道 |

- 每个 Gate 维护 `频道 -> 本地会话集合`；会话登录时按出生服自动订阅 `game:` / `zone:` / `global`，**合服或调战区后由目录变化通知重新订阅**。
- 公会、队伍频道由实体发起订阅（加入队伍时，队伍实体通知各成员会话所在的 Gate），断线自动退订。
- 发布：`channel.publish(name, msg)` 发给所有 Gate 节点，各自只投递给本地订阅者。

---

## 六、跨服玩法范式：以跨服组队为例

所有跨服玩法都按同一个模式搭：**作用域实体负责撮合，临时实体负责活动，玩家实体始终是自己数据的唯一写入者。**

```
role(A, game1) ──┐                         ┌──> team:<id>（临时实体）
role(B, game2) ──┼──> match:zone1（作用域实体，每战区一份）──┤
role(C, game2) ──┘        撮合                └──> battle:<id>（临时实体或场景服）
```

1. **报名**：role 实体把自己的**只读快照**（等级、战力、出生服、显示名）发给 `match:zone1`。快照只用于匹配和展示，过期就重取。
2. **组队**：匹配成功后创建 `team:<id>` 临时实体，记录成员 rid 和快照；各成员 role 实体在内存里记下 `team_id`，并订阅 `team:<id>` 频道。
3. **活动中**：队伍、战斗实体只读快照、只改自己的状态。需要给玩家推送时走频道或 `send_loaded`。
4. **结算**：奖励、积分通过**可靠消息**发回各成员的 role 实体，按 `msg_id` 去重。成员离线也能在下次登录时收到。
5. **边界检查**：`match:zone1` 只接受 `realm.zone_of(realm.game_of(role.server)) == "zone1"` 的报名，由功能自己检查。

这个模式下不会出现第一代跨服"一个角色两份可写数据"的问题：跨服活动无论怎么组合，玩家数据都只在 role 实体里改。

## 七、跨实体事务

实体加载期间内存是权威、数据库只是快照，所以不能靠 Mongo 多文档事务保证跨实体一致。跨实体操作一律通过可靠消息 + 幂等完成：

- **单向转移**（赠送、发奖励、邮件附件）：发起方先扣，再 `reliable_send` 给接收方加。按作用域表，**带物品的转移要检查双方同 game**。
- **双向交换**（交易）：一个交易实体做协调者，持久化状态机：向双方发 `reserve` 冻结物品 → 都成功则发 `commit`，任一失败或超时则发 `release`。每一步都是可靠消息，交易实体重启后从持久化状态继续。框架提供 `skyext.entity.saga` 帮助库。

---

## 基建改造清单

| 模块 | 改造 |
|------|------|
| 配置 | `server2game` 删除，改为 etcd 中的区服目录；新增 `skyext.realm` |
| 角色 schema | 删除 `game` 字段，只保留出生服 `server`；新增名字表 `(server, name)` 唯一 |
| Account | `/servers` 服务器列表从目录读取（含状态、推荐服）；建角写名字表 |
| 实体系统 | `scope`（作用域实体，按目录自动预加载、合服钩子）；`persistent = false`（临时实体）；`router.call_loaded/send_loaded`；`router.scoped_call` |
| 网关 | 新增 Gate 服务与会话层，替换 role 节点里的 watchdog/login/client_ext 接入方式；会话迁移接入停服编排 |
| 频道 | 新增 `skyext.channel`，挂在 Gate 层 |
| GM | `realm_open`（开服）、`realm_merge`（合服）、`realm_set_zone`（调战区） |
| 示例 | 排行榜改为 `scope = "game"`；新增跨服匹配 + 组队示例；交易示例 |

## 推进顺序

| 阶段 | 内容 | 依赖 |
|------|------|------|
| 1 | 常驻实体、实体定时器、排行榜示例 —— **已完成** | — |
| 2 | 区服目录 `skyext.realm`；角色只记出生服；名字表；作用域实体（`scope`、自动预加载）；Account `/servers`；GM 开服 —— **已完成** | — |
| 3 | 独立网关层：会话、亲和转发、下行推送、登录迁到 Gate、同进程部署 —— **已完成** | — |
| 4 | 无感迁移：会话 migrate 接入停服与交接；滚动发版验证 | 3 |
| 5 | 频道与广播（按作用域自动订阅） | 3 |
| 6 | 临时实体、`call_loaded`；跨服匹配 + 组队示例 | 2、5 |
| 7 | 合服编排（`realm_merge`、`on_merge` 钩子）；saga 帮助库与交易示例 | 2 |

阶段 2 和阶段 3 互不依赖，可以并行。

## 不在本次范围

- **场景与 AOI**：实时同步类玩法需要按空间分片的场景服，与"按 ID 寻址的实体"是不同模型。跨服战场里的实时战斗部分属于这一类，本设计只负责把玩家撮合进去、把结果写回来。
- **etcd 不可用时的降级**：etcd 连续约 28 秒不可达会全服掉线（见[架构概览](../overview.md)）。区服目录放进 etcd 后，etcd 的重要性进一步提高，降级方案需要单独评估。
- **Mongo 分片**：玩家数据量到一定规模后按 `rid` 哈希分片。实体系统按 ID 读写、没有跨文档查询，天然适合分片，届时只是部署层面的事。

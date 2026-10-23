# 登录流程

> 可视化展示见 [登录流程图](login_diagram.md)。要实现一个客户端 SDK，看 [客户端接入规范](client_protocol.md)——那份文档才是实现依据，本文讲的是服务端这一侧怎么配、怎么跑。

## 前置条件

- Account 服务已启动（提供 `/servers`、`/gates`、`/roles`、`/create_role` 以及开发用的 `/dev_login` HTTP 接口）
- 至少一个网关节点已启动并监听（Role 节点同进程部署的网关，或独立的 Gateway 节点；客户端连任意一个都能进游戏）
- etcd 和 MongoDB 服务可用
- 客户端持有有效的 JWT Token（正式客户端从 SDK/平台登录服务获取；示例机器人从 Account 的 `/dev_login` 获取）

## 登录步骤

1. 客户端获取 JWT Token（正式客户端从 SDK/平台登录服务获得；示例机器人 POST `/dev_login` 获得）
2. HTTP GET `/servers` 取服务器列表（不需要登录，最新开放的服带 `recommended = true`），选一个服建角
3. HTTP GET `/roles` 取角色列表；没有角色时 POST `/create_role` 创建（只能选 `status = "open"` 的服）。两个接口都要带 `Authorization: Bearer <token>` 头——**token 不走 URL query**，那会被访问日志、代理日志、Referer 和浏览器历史一路抄送
4. HTTP GET `/gates` 取在线网关列表（不需要登录），挑一台连上。原生 APP 连 `tcp_addr`（裸 TCP，2 字节大端长度前缀），浏览器和小程序连 `ws_url`（WebSocket binary 帧，不加长度头）。**客户端不需要知道角色实体在哪个节点**——网关只管会话，上行包由它转发到实体真正所在的节点
5. 发送 sproto `login.login`（携带 token、rid、server、proto_checksum）。服务端校验 token 后，还会查角色文档确认这个 rid **属于 token 里的账号、且在请求的区服**，否则返回 `ROLE_NOT_EXIST`——token 只证明账号，rid 和 server 是客户端自己报的
6. 登录服务经 Entity 路由调用 `router.bind_session("role", rid, ...)`：按 HRW 找到实体所在节点，把这条会话绑到角色实体上（实体可能在别的节点，网关会记下 `owner_node`，后续上行包跨节点转发）。**不再有 `NOT_THIS_NODE` 让客户端改连节点**
7. 登录响应里带回一枚 `nonce`（16 字节续接凭据），客户端存下来，断线后用它走 `login.resume` 把会话接回去，见下面的[断线续接](#断线续接)
8. 登录成功后发送 sproto `role.login_info` 获取角色详细信息

### 开发用登录接口

`POST /dev_login`，body `{"account": "robot1"}`，返回 `{"code": 0, "token": "..."}`。它按账号名直接签发登录 token，**不校验任何身份**，只供本地开发和机器人使用；由 `dev_login_enable` 控制，不配就返回 404。正式环境必须关掉，token 由 SDK/平台登录服务在验明身份后用同一套 `login_jwt_*` 配置签发。

### Token 的签名算法

`login_jwt_alg` 支持两类算法，差别只在"谁手上有能签 token 的东西"：

| 算法 | 密钥 | 签发方配 | 校验方配 |
| --- | --- | --- | --- |
| `HS256` / `HS512` | 共享密钥 | `login_jwt_secret` | 同一个 `login_jwt_secret` |
| `RS256` / `ES256` | 公私钥 | `login_jwt_private_key[_path]` | `login_jwt_public_key[_path]` |

共享密钥的问题是校验方必须拿到签名密钥，于是每台游戏节点都具备伪造登录态的能力，泄露一台等于全盘失守。token 由外部平台签发时更麻烦——密钥得跨组织传递。换成公私钥后私钥只留在签发方，游戏节点只拿公钥，公钥泄露无所谓。

`ES256`（P-256）签名 64 字节，比 `RS256`（2048 位起步）的 256 字节短得多，token 体积差一大截，优先选它。生成一对：

```sh
openssl ecparam -name prime256v1 -genkey -noout -out login_priv.pem
openssl ec -in login_priv.pem -pubout -out login_pub.pem
```

私钥不能带口令——服务端不会去问密码，带口令的私钥会被直接判为配置错误。

密钥轮转时让 `login_jwt_public_key` 写成 kid 到 PEM 的表，新旧两把同时信任；签发方配上 `login_jwt_kid`，签出来的 token 头里就带着该用哪一把：

```lua
login_jwt_public_key = { ["login-2025"] = old_pem, ["login-2026"] = new_pem }
```

等所有旧 token 都过期（最长 `login_jwt_ttl` 秒）之后再把旧公钥删掉。

有一点是写死在实现里的：**算法由密钥决定，不由 token 头里的 `alg` 决定**。配了公钥的节点只会走验签，拿到一个声称 `HS256` 的 token 会直接拒绝，而不是把公钥当成 HMAC 密钥去算——后者是 JWT 最经典的伪造手法，公钥本来就是公开的，谁都能用它签出一个"合法"的 HS256 token。同理，`login_jwt_alg` 配的是 `RS256` 时，连同族的 `ES256` token 也一并拒绝。

## Robot 登录创角示例

机器人使用 Lua 客户端 SDK（`sdk/lua/`）：Account HTTP 走 `skyext.client.account`，会话走 `skyext.client.session`。以下代码来自 `example/nodes/robot/robotagent/main.lua`：

```lua
local client_account = require "skyext.client.account"
local client_session = require "skyext.client.session"

function CMD.start(conf)
    local account = client_account.new({ hosts = { config.get("account_host") } })
    local name = "robot" .. conf.id
    -- 拿登录 token。示例走 Account 的开发登录接口；正式客户端从平台登录服务拿
    local token = account:dev_login(name)
    -- GET /servers 挑推荐服；GET /roles，没有角色时 POST /create_role
    local role = account:ensure_role(token, name, account:pick_recommended_server() or "s1")
    -- 网关地址来自 account 的 /gates，不写死在配置里。列表里只会有真的在线的网关
    -- （网关键挂在节点租约上），所以也不用自己判断某个端口通不通
    local gates = account:gates()

    -- 按编号错开起点，依次试到第一个跑通的网关；网关不必和角色实体在同一个节点
    local start = conf.gate or (conf.id % #gates + 1)
    for i = 0, #gates - 1 do
        local gate = gates[(start + i - 1) % #gates + 1]
        -- 同一套用例在 tcp 和 ws 上各跑一遍，行为必须完全一致
        for _, transport in ipairs(config.get_table("robot_transports") or { "tcp", "ws" }) do
            run(transport, gate, role, token)
        end
    end
end
```

Account 接口把登录 token 放在 Authorization 头（不进 URL），传输失败自动换下一台 host，实现见 `sdk/lua/skyext/client/account.lua`。

连接、登录、计数、心跳、续接这些都在 `skyext.client.session`（`sdk/lua/skyext/client/session.lua`）里，机器人只负责编排业务流程。`run()` 建一个会话，跑一遍业务，中间主动断一次连接验证续接，再跑一遍：

```lua
local s = client_session.new({
    transport = transport, -- "tcp" 或 "ws"
    host = host,
    port = port,
    url = gate.ws_url,
    login_param = function()
        return { token = token, rid = role.rid, server = role.server, proto_checksum = ... }
    end,
})
s:start()
play(s, role.rid)
check_resume(s) -- 断开、续接、断言凭据轮换且计数没有倒退
play(s, role.rid)
s:close()
```

## 断线续接

断线不等于重新登录。客户端重连后先发 `login.resume`，把会话接回新连接上：在途请求按原 id 重发（服务端回缓存的响应，不重复执行），断线期间的下行包重放过来，业务层**观察不到**这次断线（不触发 `on_bind_client` / `on_unbind_client`）。

服务端这一侧的要点：

- **会话活在角色实体进程里**，不在网关里。`entity.session` 是连接（断了就是 nil），`entity.session_io` 才是会话，它跨连接存活
- **续接窗口 = 实体的 `unload_delay`**。没有单独的计时器：实体卸载时会话一起消失，续接自然失败并退化成完整登录
- **续接能落到任意一台网关**。会话键 `<gate_node>/<fd>` 全集群唯一，实体寻址与网关在哪无关
- **凭据每次轮换**。`login` 和每次成功的 `resume` 都返回新的 nonce，旧的立即失效；比对是恒定时间的
- **不加载实体**。`resume` 不验 token、不查库、不抢锁，实体不在内存里就直接失败

相关配置都在 `example/etc/nodes/common.app.lua`：

| 配置 | 作用 | 默认 |
| --- | --- | --- |
| `session_replay_bytes` / `session_replay_packets` | 未确认下行的重放缓冲上限 | 32 KiB / 256 包 |
| `session_respcache_count` / `session_respcache_bytes` | 上行幂等缓存上限 | 64 条 / 16 KiB |
| `session_idle_timeout` | 多久没有上行包就断开连接 | 60 秒 |
| `session_idle_interval` | 空闲扫描间隔 | 10 秒 |

两个缓冲上限是**内存保护**，不是性能参数：撑爆了只是退化成重新登录，取大了则是每个在线角色都多占这么多常驻内存。

客户端那一侧的义务（计数、心跳、原 id 重发、不假设重放与响应保序）一条都不能省，全部写在[客户端接入规范](client_protocol.md)里。设计取舍见 `docs/design/session_resume.md`。

## 登录协议定义

### login（协议号 100）

定义于 `example/proto/login.sproto`：

```sproto
# 角色登录
login 100 {
    request {
        token 0 : string # jwt token {account}
        rid 1 : integer # role id 直接登录角色
        proto_checksum 2 : string # 协议文件 checksum
        server 3 : string # 区服ID
    }
    response {
        code 0 : integer
        rid 1 : integer
        nonce 2 : string # 续接凭据，断线后拿它走 resume
    }
}
```

另外两条 `login.resume`（101）和 `login.ping`（102）属于会话层，含义和客户端义务见[客户端接入规范](client_protocol.md)。

> **登出**：没有专门的登出协议。客户端直接关闭连接即视为登出——网关把断开事件转给角色实体，实体解绑会话（触发 `on_unbind_client` 钩子），数据由实体系统的定时保存与卸载统一落库。

### role.login_info（协议号 200）

定义于 `example/proto/roleagent/role.sproto`：

```sproto
# 角色登录信息
login_info 200 {
    request {}
    response {
        code 0 : integer
        info 1 : role
    }
}
```

> 当 `proto_checksum_enable = true`（示例配置已启用，见 `example/etc/nodes/common.app.lua`）时，服务端校验客户端的 `proto_checksum` 字段，版本不一致会拒绝登录。

## 服务端点配置

以下配置分布在 `example/etc/nodes/` 下各节点配置文件中。

### Account 服务

HTTP 服务，端口由各节点的 `account_http_port` 指定：

| 节点 | 配置文件 | 端口 |
|------|---------|------|
| account1 | `example/etc/nodes/account1.app.lua` | 8080 |
| account2 | `example/etc/nodes/account2.app.lua` | 8081 |

机器人配置指定单个 Account 地址（`example/etc/nodes/robot.app.lua`）：

```lua
account_host = "http://127.0.0.1:8080"
```

### 网关地址

网关地址**不配在客户端**。每个网关节点启动时把自己的接入地址上报进区服目录（etcd 的 `/skyext/realm/gate/<node>`，挂在节点租约上），客户端请求 `GET /gates` 拿列表：

```json
{ "code": 0, "gates": [
  { "node": "gate1", "tcp_addr": "127.0.0.1:7052", "ws_url": "ws://127.0.0.1:7053", "weight": 1 }
] }
```

节点挂掉时租约过期、键消失；节点优雅停服时在 `stop_accepting` 阶段主动摘掉自己——已连上的客户端照常走完停服流程，新客户端立刻不再被引导过来。

**这意味着前面不需要挂会话保持（sticky）的负载均衡**：续接能落到任意一台网关（会话状态在角色实体里，不在网关里），客户端从列表里随便挑都行。手机从 WiFi 切 4G 时源 IP 会变，粘性恰恰在最需要续接的那一刻失效。

各节点的端口配置：

| 节点 | 配置文件 | gate_port | ws_port | GM 端口 |
|------|---------|-----------|---------|---------|
| rolenode1 | `example/etc/nodes/role1.app.lua` | 7012 | 7013 | 9092 |
| rolenode2 | `example/etc/nodes/role2.app.lua` | 7022 | 7023 | 9093 |
| gate1（独立网关） | `example/etc/nodes/gate1.app.lua` | 7052 | 7053 | 9094 |

`ws_port` 不配就只开裸 TCP 网关。下发给客户端的是公网可达地址，和监听地址（`gate_host`，通常 `0.0.0.0`）不是一回事：

| 配置 | 作用 | 默认 |
| --- | --- | --- |
| `gate_public_host` | 下发给客户端的主机名/IP | `cluster_host` |
| `ws_public_url` | 整条 WS URL，前面挂了 TLS 终止、客户端连域名 443 时配它 | 由 `ws_protocol` + `gate_public_host` + `ws_port` 拼出 |
| `gate_weight` | 客户端分流权重 | 1 |

### wss

小程序平台要求已备案、证书合法的域名，端口基本只能 443，所以线上这一侧大概率要前置一层做 TLS 终止，`ws_protocol` 留 `ws` 即可——那一层只做 TLS 和转发，**不做会话保持**。

直连 `wss` 是给小规模自建部署用的，在节点配置里写：

```lua
ws_protocol = "wss"
ws_certfile = "etc/keys/server-cert.pem"
ws_keyfile = "etc/keys/server-key.pem"
```

再在该节点的 `.conf.lua` 里加 `enablessl = true`（ltls 要用）。这几项**不能写进 `common.app.lua`**：节点配置的最后一行是 `include "common.app.lua"`，公共文件里的赋值会反过来把节点自己写的那份盖掉。

### 区服目录

区服（server）→ 逻辑服（game）→ 战区（zone）的映射存在 etcd 的区服目录里，由 GM 命令 `realm_open`、`realm_set_zone` 维护，见[架构概览](../overview.md)。`example/etc/nodes/common.app.lua` 里的 `realm_seed` 只在目录完全为空时写入一次，供本地开发和新环境首次启动：

```lua
realm_seed = {
    zones = { zone1 = {} },
    games = { game1 = { zone = "zone1" }, game2 = { zone = "zone1" } },
    servers = {
        s1 = { game = "game1", name = "一区", tag = "S1" },
        s2 = { game = "game2", name = "二区", tag = "S2" },
        s3 = { game = "game2", name = "三区", tag = "S3" }, -- 三区合入 game2
    },
}
```

客户端用 `GET /servers` 取服务器列表（不需要登录，最新开放的服带 `recommended = true`）。建角只能选 `status = "open"` 的服；角色只记出生服，登录时报的 `server` 必须是角色的出生服。角色名在出生服内唯一，跨服场景里显示为 `[S3]张三`。

角色实体落在哪个节点由 Entity 系统按服务发现报告的存活节点（rendezvous hashing）计算，对客户端透明——客户端只连任意一个 gate，由 gate/登录服务把会话绑到实体真正所在的节点。`entity_types.role.nodes`（`common.app.lua`）只在服务发现不可用时兜底。

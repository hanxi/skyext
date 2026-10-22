# 登录流程

> 查看 [登录流程图](login_diagram.md) 了解完整的登录流程可视化展示

## 前置条件

- Account 服务已启动（提供 `/servers`、`/roles`、`/create_role` 以及开发用的 `/dev_login` HTTP 接口）
- gate 已启动并监听（Role 节点同进程部署的 gate，或独立的 Gateway 节点；客户端连任意一个 gate 都能进游戏）
- etcd 和 MongoDB 服务可用
- 客户端持有有效的 JWT Token（正式客户端从 SDK/平台登录服务获取；示例机器人从 Account 的 `/dev_login` 获取）

## 登录步骤

1. 客户端获取 JWT Token（正式客户端从 SDK/平台登录服务获得；示例机器人 POST `/dev_login` 获得）
2. 发送 HTTP GET `/servers` 获取服务器列表（不需要登录，最新开放的服带 `recommended = true`），选一个服建角
3. 发送 HTTP GET `/roles?token=xxx` 到 Account 服务获取角色列表；没有角色时 POST `/create_role` 创建（只能选 `status = "open"` 的服）
4. 连接任意一个 gate（正式客户端经 gate 前的负载均衡/goscon 转接，机器人从 `gate_addrs` 列表里依次试到第一个连得上的，用 TCP `socket.open` 直连）。**客户端不需要知道角色实体在哪个节点**——gate 只管会话，上行包由它转发到实体真正所在的节点
5. 发送 sproto `login.login` 消息（携带 token、rid、server、proto_checksum）。服务端校验 token 后，还会查角色文档确认这个 rid **属于 token 里的账号、且在请求的区服**，否则返回 `ROLE_NOT_EXIST`——token 只证明账号，rid 和 server 是客户端自己报的
6. 登录服务经 Entity 路由调用 `router.bind_session("role", rid, gate_node, fd)`：按 HRW 找到实体所在节点，把这条 gate 会话绑到角色实体上（实体可能在别的节点，gate 会记下 `owner_node`，后续上行包跨节点转发）。**不再有 `NOT_THIS_NODE` 让客户端改连节点**
7. 登录成功后发送 sproto `role.login_info` 获取角色详细信息

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

以下代码来自 `example/nodes/robot/robotagent/main.lua`：

```lua
-- 拿登录 token。示例走 Account 的开发登录接口；正式客户端从 SDK/平台登录服务拿
local function fetch_token(account_host, account)
    local status, res = httpc.post_json(account_host, "/dev_login", { account = account })
    if status ~= 200 or type(res) ~= "table" or res.code ~= errcode.OK then
        log.error("dev_login failed", "status", status, "res", res)
        return nil
    end
    return res.token
end

function CMD.start(conf)
    -- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的是 nil，
    -- 所以 account_host 和 gate_addrs 都要在这里取
    local account_host = config.get("account_host")
    local gate_addrs = assert(config.get_table("gate_addrs"), "gate_addrs is not configured")
    local account = "robot" .. conf.id
    local token = fetch_token(account_host, account)
    if not token then
        return
    end

    -- 服务器列表不需要登录；没有角色时在推荐服建角
    local server = "s1"
    local list_status, list = httpc.get(account_host, "/servers")
    local servers = list_status == 200 and cjson.decode(list)
    for _, entry in ipairs(servers and servers.servers or {}) do
        if entry.recommended then
            server = entry.server
        end
    end

    local status, body = httpc.get(account_host, "/roles?token=" .. token)
    -- ……没有角色时 POST /create_role（带 server）创建，取第一个角色……

    local role = roles[1]
    -- 按编号错开起点，依次试到第一个连得上的 gate；gate 不必和角色实体在同一个节点
    local fd = connect_gate(gate_addrs, conf.gate or (conf.id % #gate_addrs + 1))
    if not fd then
        log.error("no gate is reachable", "gate_addrs", gate_addrs)
        return
    end
    g_fd = fd

    local ret = call("login.login", {
        token = token,
        rid = role.rid,
        server = server,
        proto_checksum = sproto_api.get_sproto_info().checksum,
    })
    if not ret or ret.code ~= errcode.OK then
        return
    end
    -- 登录后看背包、给自己发一封邮件、看邮箱，再报一次排行榜
    play(role.rid)
end
```

> **说明**：机器人使用 `socket.open` 建立原始 TCP 连接直连 skynet gate。正式客户端通常经 WebSocket 网关（如 [goscon](https://github.com/hanxi/goscon)）转接到 skynet gate 的 TCP 端口。

## 登录协议定义

### login（协议号 101）

定义于 `example/proto/login.sproto`：

```sproto
# 角色登录
login 101 {
    request {
        token 0 : string # jwt token {account}
        rid 1 : integer # role id 直接登录角色
        proto_checksum 2 : string # 协议文件 checksum
        server 3 : string # 区服ID
    }
    response {
        code 0 : integer
        rid 1 : integer
    }
}
```

> **登出**：没有专门的登出协议。客户端直接关闭连接即视为登出——gate 把断开事件转给角色实体，实体解绑会话（触发 `on_unbind_client` 钩子），数据由实体系统的定时保存与卸载统一落库。

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

### 网关地址（gate_addrs）

机器人从 `gate_addrs` 列表里按编号错开起点、依次试到第一个连得上的 gate，不关心角色实体在哪个节点。配置示例（`example/etc/nodes/robot.app.lua`）：

```lua
gate_addrs = {
    { ip = "127.0.0.1", port = 7012 }, -- rolenode1 同进程部署的 gate
    { ip = "127.0.0.1", port = 7022 }, -- rolenode2 同进程部署的 gate
    { ip = "127.0.0.1", port = 7052 }, -- 独立的 gate1 节点
}
```

正式环境客户端连的是 gate 前面的负载均衡（或 goscon），不需要列出具体节点。各节点的 gate 端口由 `gate_port` 配置：

| 节点 | 配置文件 | gate_port | GM 端口 |
|------|---------|-----------|---------|
| rolenode1 | `example/etc/nodes/role1.app.lua` | 7012 | 9092 |
| rolenode2 | `example/etc/nodes/role2.app.lua` | 7022 | 9093 |
| gate1（独立网关） | `example/etc/nodes/gate1.app.lua` | 7052 | 9094 |

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

# 登录流程

> 查看 [登录流程图](login_diagram.md) 了解完整的登录流程可视化展示

## 前置条件

- Account 服务已启动（提供 `/roles`、`/create_role` 以及开发用的 `/dev_login` HTTP 接口）
- RoleNode（含网关 gate）已启动并监听
- etcd 和 MongoDB 服务可用
- 客户端持有有效的 JWT Token（正式客户端从 SDK/平台登录服务获取；示例机器人从 Account 的 `/dev_login` 获取）

## 登录步骤

1. 客户端获取 JWT Token（正式客户端从 SDK/平台登录服务获得；示例机器人 POST `/dev_login` 获得）
2. 发送 HTTP GET `/roles?token=xxx` 到 Account 服务获取角色列表
3. 如果没有角色，发送 HTTP POST `/create_role` 到 Account 服务创建角色
4. 创建角色返回角色信息，其中包含 `rolenode` 字段
5. 根据 `rolenode` 查找对应网关地址
6. 连接网关（正式客户端经 WebSocket 网关转接，机器人使用 TCP `socket.open` 直连）
7. 发送 sproto `login.login` 消息（携带 token、rid、server、proto_checksum）。服务端校验 token 后，还会查角色文档确认这个 rid **属于 token 里的账号、且在请求的区服**，否则返回 `ROLE_NOT_EXIST`——token 只证明账号，rid 和 server 是客户端自己报的
8. rid 不该落在本节点时返回 `NOT_THIS_NODE` 和正确的 `rolenode`，客户端改连那个节点重新登录
9. 登录成功后发送 sproto `role.login_info` 获取角色详细信息

### 开发用登录接口

`POST /dev_login`，body `{"account": "robot1"}`，返回 `{"code": 0, "token": "..."}`。它按账号名直接签发登录 token，**不校验任何身份**，只供本地开发和机器人使用；由 `dev_login_enable` 控制，不配就返回 404。正式环境必须关掉，token 由 SDK/平台登录服务在验明身份后用同一套 `login_jwt_*` 配置签发。

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
    local account_host = config.get("account_host")
    local gate_nodes = assert(config.get_table("gate_nodes"), "gate_nodes is not configured")
    local account = "robot" .. conf.id
    local token = fetch_token(account_host, account)
    if not token then
        return
    end

    local status, body = httpc.get(account_host, "/roles?token=" .. token)
    -- ……没有角色时 POST /create_role 创建，取第一个角色……

    local role = roles[1]
    local rolenode = role.rolenode
    local fd, err = socket.open(gate_nodes[rolenode].ip, gate_nodes[rolenode].port)
    if not fd then
        log.error("failed to connect to gate", "err", err)
        return
    end
    g_fd = fd

    local ret = call("login.login", {
        token = token,
        rid = role.rid,
        server = "s1",
        proto_checksum = sproto_api.get_sproto_info().checksum,
    })
    if not ret or ret.code ~= errcode.OK then
        return
    end
    -- 登录后看背包、给自己发一封邮件、再看邮箱
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
        rolenode 2 : string # 需要连的游戏节点
    }
}

# 角色登出
logout 102 {}
```

### role.login_info（协议号 200）

定义于 `example/proto/roleagent/role.sproto`：

```sproto
# 角色登录信息
login_info 200 {
    request {}
    response {
        info 0 : role
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

### 网关节点（gate_nodes）

机器人通过 `gate_nodes` 配置查找各 RoleNode 的网关地址。配置示例（`example/etc/nodes/robot.app.lua`）：

```lua
gate_nodes = {
    rolenode1 = {
        ip = "127.0.0.1",
        port = 7012,
    },
    rolenode2 = {
        ip = "127.0.0.1",
        port = 7022,
    },
}
```

各 RoleNode 的网关端口由 `gate_port` 配置：

| 节点 | 配置文件 | gate_port | GM 端口 |
|------|---------|-----------|---------|
| rolenode1 | `example/etc/nodes/role1.app.lua` | 7012 | 9092 |
| rolenode2 | `example/etc/nodes/role2.app.lua` | 7022 | 9093 |

### 区服与游戏服映射

`server2game` 配置在 `example/etc/nodes/common.app.lua`，将客户端区服 ID 映射到内部游戏服：

```lua
server2game = {
    ["s1"] = "game1",
    ["s2"] = "game2",
    ["s3"] = "game2", -- game3 合服到 game2
}
```

角色的 `rolenode` 由 Entity 系统按服务发现报告的存活节点（rendezvous hashing）计算；`entity_types.role.nodes`（`common.app.lua`）只在服务发现不可用时兜底。

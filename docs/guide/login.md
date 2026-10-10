# 登录流程

> 查看 [登录流程图](guide/login_diagram.md) 了解完整的登录流程可视化展示

## 登录步骤

1. 客户端发送 HTTP GET `/roles?token=xxx` 去 account 服务获取角色列表
2. 如果有角色，从返回的角色列表中选择一个角色
3. 如果没有角色，发送 HTTP POST `/create_role` 去 account 服务创建角色
4. 创建角色会返回一个角色信息 role
5. 角色信息中会带有 rolenode 节点数据
6. 使用 WebSocket 连接 rolenode 对应的 wsUrl
7. 发送 sproto `login.login` 消息
8. 登录成功再发送 sproto `role.login_info` 消息

## Robot 登录创角示例

```lua
function CMD.start(conf)
    local data = {
        account = "robot3",
    }
    local token = jwt.sign(data, login_jwt_secret, "HS512", 60)
    log.info("generate token", "token", token)

    local account_host = config.get("account_host")
    local status, body = httpc.get(account_host, "/roles?token=" .. token)
    if status ~= 200 then
        log.error("failed to get roles", "status", status, "body", body)
        return
    end
    local res = cjson.decode(body)
    if res.code ~= errcode.OK then
        log.error("failed to get roles", "res", res)
        return
    end

    local roles = res.roles
    if #roles == 0 then
        local req = {
            token = token,
            server = "s1",
            name = "robot3",
        }
        local status, res = httpc.post_json(account_host, "/create_role", req)
        if status ~= 200 then
            log.error("failed to create role", "status", status, "res", res)
            return
        end
        if res.code ~= errcode.OK then
            log.error("failed to create role", "res", res)
            return
        end
        roles = { res.role }
    end

    if #roles == 0 then
        log.error("no roles available")
        return
    end

    local role = roles[1]
    local rolenode = role.rolenode
    local gate_ip = gate_nodes[rolenode].ip
    local gate_port = gate_nodes[rolenode].port
    local fd, err = socket.open(gate_ip, gate_port)
    if not fd then
        log.error("failed to connect to gate", "err", err)
        return
    end
    g_fd = fd
    log.info("connected to gate", "ip", gate_ip, "port", gate_port)

    local param = {
        token = token,
        rid = role.rid,
        server = "s1",
        proto_checksum = sproto_api.get_sproto_info().checksum,
    }
    local ret = call("login.login", param)
    log.info("login response", "ret", ret)
    local ret = call("role.login_info")
    log.info("login_info response", "ret", ret)
end
```

## 登录协议定义

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

## 服务端点配置

### Account 服务

HTTP 服务，多个地址任意选一个：

```json
[
    "http://127.0.0.1:8080",
    "http://127.0.0.1:8081"
]
```

### RoleNode 列表

类似游戏网关 gate 列表，每个节点有对应的 wsUrl，根据 `role.rolenode` 路由到对应的 rolenode 节点：

```json
{
  "rolenode1": "ws://localhost:1249",
  "rolenode2": "ws://localhost:1249"
}
```

### 完整服务器列表信息

```json
{
    "servers": {
        "s1": { "name": "测试服务器1", "server": "s1" },
        "s2": { "name": "测试服务器2", "server": "s2" }
    },
    "rolenodes": {
        "rolenode1": "ws://localhost:1249",
        "rolenode2": "ws://localhost:1249"
    },
    "account_hosts": [
        "http://127.0.0.1:8080",
        "http://127.0.0.1:8081"
    ]
}
```

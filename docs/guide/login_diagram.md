# 登录流程图

本文是[登录流程](login.md)的图示版，只画链路。配置项、错误码、HTTP 接口以那篇为准；客户端要实现哪些义务见[客户端接入规范](client_protocol.md)。集群拓扑和端口分布见[架构概览](../overview.md)的「示例部署」图。

两种登录方式的差别只在"token 从哪来"，拿到 token 之后的链路完全一样：

- **正式客户端**：走外部 OAuth 服务（示例用 gamepass）拿 JWT Token
- **机器人 / 开发客户端**：向 Account 的 `POST /dev_login` 要 token，正式环境必须关掉这个接口

网关节点同时监听 TCP 和 WebSocket 两个端口，分别由 `service/gate_tcp.lua` 和 `service/gate_ws.lua` 承载，两者之上是同一套会话层，协议、登录、续接完全一致。客户端二选一直连即可，中间不需要任何代理；地址不写死在客户端里，由 `GET /gates` 下发。

## 完整登录流程

```mermaid
flowchart TD
    A[客户端启动] --> C{手上有有效 token?}
    C -->|没有，正式客户端| D["走 OAuth 登录<br/>gamepass 回调返回 JWT"]
    C -->|没有，机器人| D2["POST /dev_login<br/>按账号名直接签发"]
    C -->|有| SV
    D --> SV
    D2 --> SV

    SV["GET /servers<br/>选一个 status=open 的服"] --> I["GET /roles<br/>Authorization: Bearer token"]
    I --> J{有角色?}
    J -->|有| K[选一个角色]
    J -->|没有| L["POST /create_role"]
    L --> M{建角成功?}
    M -->|否| O[登录失败]
    M -->|是| K

    K --> GL["GET /gates<br/>拿在线网关列表"]
    GL --> P["挑一台，连 tcp_addr 或 ws_url<br/>客户端不需要知道实体在哪个节点"]
    P --> S{连上了?}
    S -->|没有，换下一台| P
    S -->|没有，列表试完了| T[连接失败]
    S -->|是| U["login.login<br/>token · rid · server · proto_checksum"]

    U --> V{code == OK?}
    V -->|否| W[登录失败]
    V -->|是| NC["存下响应里的 nonce<br/>下行计数清零"]
    NC --> X["role.login_info"] --> Y[进入游戏]
```

## 登录时序

```mermaid
sequenceDiagram
    participant C as 客户端
    participant GP as OAuth 服务 / dev_login
    participant A as Account 节点
    participant G as 网关 gate_tcp / gate_ws
    participant L as 登录服务
    participant E as 角色实体进程

    C->>GP: 鉴权
    GP-->>C: JWT token
    C->>A: GET /servers
    A-->>C: 区服列表（带 recommended）
    C->>A: GET /roles（Bearer token）
    A-->>C: 角色列表
    opt 没有角色
        C->>A: POST /create_role { server, name }
        A-->>C: { code, role }
    end
    C->>A: GET /gates
    A-->>C: [{ node, tcp_addr, ws_url, weight }]

    C->>G: 直连其中一台（TCP 或 WS）
    C->>G: login.login { token, rid, server, proto_checksum }
    G->>L: 这条连接还没绑定，交给登录服务
    Note over L: 校验 JWT，核对协议 checksum，<br/>查库确认 rid 属于该账号且在该区服
    L->>E: router.bind_session("role", rid, ...)
    Note over E: 按 HRW 定位节点、加载实体、<br/>重建会话并生成 nonce
    E-->>L: OK, nonce
    L-->>C: { code, rid, nonce }
    Note over G: 之后这条连接的上行包<br/>由网关直接转给实体所在节点
    C->>E: role.login_info
    E-->>C: 角色信息
```

## 断线之后：先续接，续不上再重新登录

断线不等于重新登录。实体还在内存里（能等多久由它的 `unload_delay` 决定）的话，拿 `nonce` 走 `login.resume` 可以把会话接回去，断线期间漏掉的下行包会被重放出来，业务层察觉不到这次断线。

```mermaid
flowchart TD
    D0[连接断开] --> D1{手上有 nonce?}
    D1 -->|没有| FL[走完整登录流程]
    D1 -->|有| D2["GET /gates 重新取列表<br/>原来那台可能已经下线"]
    D2 --> D3[连一台网关]
    D3 --> D4["login.resume<br/>rid · nonce · recv=已收到的下行包数"]
    D4 --> D5{code == OK?}
    D5 -->|否| CL[清掉 nonce]
    CL --> FL
    D5 -->|是| D6["存下轮换后的新 nonce<br/>按原 request id 重发在途请求"]
    D6 --> D7[服务端重放缺失的下行包]
    D7 --> D8[继续游戏，业务层无感]
```

> `resume` 失败的错误码不用分类处理：**任何**失败都是同一个动作——清掉 nonce，走完整登录。续接是优化，不是必需路径。

续接在网关、登录服务、实体之间的详细时序（含 nonce 轮换、计数核对、重放与响应不保序）见[客户端接入规范](client_protocol.md)的「续接时序」一节。

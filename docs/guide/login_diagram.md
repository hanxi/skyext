# 登录流程图

本文是[登录流程](login.md)的图示版。要写客户端 SDK 的话，规范在[客户端接入规范](client_protocol.md)，那边有逐条的客户端义务；这里只画链路。

## 概述

两种认证方式，区别只在"token 从哪来"，拿到 token 之后的链路完全一样：

1. **正式客户端**：走 GamePass OAuth 拿 JWT Token
2. **机器人/开发客户端**：向 Account 的 `POST /dev_login` 要 token，正式环境关掉这个接口

> **传输协议说明**：网关节点同时监听 TCP 和 WebSocket 两个端口，分别由 `service/gate_tcp.lua` 和 `service/gate_ws.lua` 承载，两者之上是同一套会话层，协议、登录、续接完全一致。客户端二选一直连即可，中间不需要任何代理。地址不写死在客户端里，由 `GET /gates` 下发。

## 完整登录流程（正式客户端）

```mermaid
flowchart TD
    A[客户端启动] --> B[检查登录状态]
    B --> C{是否已有有效Token?}

    C -->|否| D[启动OAuth登录流程]
    C -->|是| H[使用现有JWT Token]

    D --> E[跳转到GamePass OAuth页面]
    E --> F[用户在GamePass完成认证]
    F --> G[OAuth回调返回JWT Token]
    G --> H

    H --> I["HTTP GET /roles<br/>Authorization: Bearer token<br/>向Account服务获取角色列表"]

    I --> J{是否有角色?}

    J -->|有角色| K[从角色列表中选择角色]
    J -->|无角色| L[HTTP POST /create_role<br/>创建新角色]

    L --> M{创建成功?}
    M -->|成功| N[获取新创建的角色信息]
    M -->|失败| O[登录失败]

    N --> K
    K --> GL["HTTP GET /gates<br/>拿到在线网关列表"]
    GL --> P["按权重挑一台，连它的 tcp_addr 或 ws_url<br/>客户端不需要知道角色实体在哪个节点"]

    P --> S{连接成功?}
    S -->|失败| S2{还有别的网关?}
    S2 -->|有| P
    S2 -->|没有| T[连接失败]
    S -->|成功| U[发送sproto login.login消息<br/>包含token, rid, proto_checksum, server]

    U --> V{登录成功?}
    V -->|失败| W[登录失败]
    V -->|成功| NC[保存响应里的 nonce<br/>断线时拿它续接]

    NC --> X[发送sproto role.login_info消息]
    X --> Y[登录完成，进入游戏]

    style A fill:#e1f5fe
    style Y fill:#c8e6c9
    style O fill:#ffcdd2
    style T fill:#ffcdd2
    style W fill:#ffcdd2
    style D fill:#fff3e0
    style E fill:#fff3e0
    style F fill:#fff3e0
    style G fill:#fff3e0
    style NC fill:#f3e5f5
```

## 断线之后：先续接，续不上再重新登录

断线不等于重新登录。实体还在内存里（由实体的 `unload_delay` 决定能等多久）的话，拿 `nonce` 走 `login.resume` 可以把会话接回去，断线期间漏掉的下行包会被重放出来，业务层察觉不到这次断线。

```mermaid
flowchart TD
    D0[连接断开] --> D1{手上有 nonce?}
    D1 -->|没有| FL[走完整登录流程]
    D1 -->|有| D2["GET /gates 重新取列表<br/>原来那台可能已经下线了"]
    D2 --> D3[连一台网关]
    D3 --> D4["发 login.resume<br/>{rid, nonce, recv=已收到的下行包数}"]

    D4 --> D5{code == OK?}
    D5 -->|失败：实体已卸载/nonce 过期/重放缓冲不够| CL[清掉 nonce] --> FL
    D5 -->|成功| D6["保存轮换后的新 nonce<br/>对比响应里的 sent 自检"]
    D6 --> D7[服务端重放缺失的下行包]
    D7 --> D8[继续游戏，业务层无感]

    style D8 fill:#c8e6c9
    style FL fill:#fff3e0
    style CL fill:#ffcdd2
```

> `resume` 失败的错误码不用分类处理：**任何**失败都是同一个动作——清掉 nonce，走完整登录。续接是优化，不是必需路径。

## 机器人客户端简化流程

```mermaid
flowchart TD
    A1[机器人客户端启动] --> B1[HTTP POST /dev_login<br/>开发接口按账号名签发Token]
    B1 --> C1["HTTP GET /roles<br/>Authorization: Bearer token"]

    C1 --> D1{是否有角色?}

    D1 -->|有角色| E1[从角色列表中选择角色]
    D1 -->|无角色| F1[HTTP POST /create_role<br/>创建新角色]

    F1 --> G1{创建成功?}
    G1 -->|成功| H1[获取新创建的角色信息]
    G1 -->|失败| I1[登录失败]

    H1 --> E1
    E1 --> J1["HTTP GET /gates<br/>拿到在线网关列表"]
    J1 --> L1["按 transport 配置连 tcp_addr 或 ws_url<br/>gate不必和角色实体在同一节点"]

    L1 --> M1{连接成功?}
    M1 -->|失败| N1[连接失败]
    M1 -->|成功| O1[发送sproto login.login消息<br/>包含token, rid, proto_checksum, server]

    O1 --> P1{登录成功?}
    P1 -->|失败| Q1[登录失败]
    P1 -->|成功| R1[发送sproto role.login_info消息]

    R1 --> S1[登录完成，进入游戏]

    style A1 fill:#e1f5fe
    style S1 fill:#c8e6c9
    style I1 fill:#ffcdd2
    style N1 fill:#ffcdd2
    style Q1 fill:#ffcdd2
    style B1 fill:#ffeb3b
```

## 认证架构

```mermaid
graph LR
    subgraph "客户端类型"
        Client[游戏客户端]
        RobotClient[机器人客户端]
    end

    subgraph "认证方式"
        GamePass[GamePass OAuth服务]
        DevLogin["Account /dev_login<br/>(dev_login_enable 控制)"]
    end

    Client -->|OAuth认证| GamePass
    GamePass -->|返回JWT Token| Client
    RobotClient -->|POST /dev_login| DevLogin
    DevLogin -->|签发JWT Token| RobotClient

    style GamePass fill:#e3f2fd
    style DevLogin fill:#fff3e0
```

## 服务集群架构

```mermaid
graph TB
    Client[客户端 / 机器人]

    subgraph "Account服务集群"
        Account1[Account服务1<br/>:8080]
        Account2[Account服务2<br/>:8081]
    end

    subgraph "Gate层（只管连接+登录，不承载实体）"
        GateR1["rolenode1 同进程 gate<br/>TCP :7012 / WS :7013"]
        GateR2["rolenode2 同进程 gate<br/>TCP :7022 / WS :7023"]
        Gate1["独立网关节点 gate1<br/>TCP :7052 / WS :7053"]
    end

    subgraph "逻辑节点池（不按区服划分，承载 role/rank 等实体）"
        RoleNode1[rolenode1]
        RoleNode2[rolenode2]
    end

    Client -->|"HTTP 服务器列表/建角/GET /gates"| Account1
    Client -->|TCP 或 WS 直连任意一个 gate| GateR1
    Client --> GateR2
    Client --> Gate1

    GateR1 -->|会话亲和转发| RoleNode1
    GateR1 --> RoleNode2
    GateR2 --> RoleNode1
    GateR2 --> RoleNode2
    Gate1 -->|跨节点转发| RoleNode1
    Gate1 -->|跨节点转发| RoleNode2

    Account1 -.->|"网关列表来自 realm<br/>键挂在节点租约上"| Gate1

    style Account1 fill:#e8f5e8
    style Account2 fill:#e8f5e8
    style Gate1 fill:#e3f2fd
    style RoleNode1 fill:#fff3e0
    style RoleNode2 fill:#fff3e0
```

> 网关节点启动时把自己的接入地址写进 realm，键挂在**节点租约**上：进程没了键跟着没，客户端不会被引导到一台已经死掉的网关。停服时的 `stop_accepting` 阶段会主动摘掉自己——已连上的客户端照常走完停服流程，新客户端不再被引导过来。

> 区服（server）→ 逻辑服（game）→ 战区（zone）是**逻辑概念**，存在 etcd 区服目录里，不对应物理节点；逻辑节点池承载所有区服的实体，开服/合服只改目录映射。见[架构概览](../overview.md)。

## 协议交互时序图

### 正式客户端 OAuth 认证流程

```mermaid
sequenceDiagram
    participant C as 客户端
    participant GP as GamePass OAuth
    participant A as Account服务
    participant R as Gate/逻辑节点

    Note over C: 1. 启动OAuth认证
    C->>GP: 跳转到OAuth认证页面
    GP-->>C: 用户完成认证，返回JWT Token

    Note over C: 2. 使用JWT Token获取角色
    C->>A: HTTP GET /roles<br/>Authorization: Bearer token
    A-->>C: 返回角色列表

    alt 如果没有角色
        C->>A: HTTP POST /create_role
        A-->>C: 返回新创建的角色
    end

    Note over C: 3. 选择角色，取网关列表
    C->>A: HTTP GET /gates
    A-->>C: [{node, tcp_addr, ws_url, weight}]

    Note over C: 4. 挑一台直连（TCP 或 WS）
    C->>R: 建立连接
    R-->>C: 连接建立成功

    C->>R: sproto login.login<br/>{token, rid, proto_checksum, server}
    Note over R: 校验token，确认rid属于token里的账号和区服，<br/>再经bind_session把会话绑定到实体所在节点
    R-->>C: 登录响应<br/>{code, rid, nonce}
    Note over C: 存好 nonce，断线时拿它续接

    C->>R: sproto role.login_info
    R-->>C: 角色信息响应

    Note over C,R: 登录完成，开始游戏
```

### 断线续接时序

```mermaid
sequenceDiagram
    participant C as 客户端
    participant G as Gate
    participant E as 角色实体进程

    Note over C,E: 连接断开，实体仍在内存里（unload_delay 窗口内）
    C->>G: 重连（可能是另一台网关）
    C->>G: sproto login.resume<br/>{rid, nonce, recv=已收到的下行包数}
    G->>E: 按 rid 路由到实体
    Note over E: 校验 nonce，算出 sent - recv 这段缺口
    E-->>C: 响应 {code, 新 nonce, sent}
    E-->>C: 重放缺失的下行包
    Note over C,E: 响应和重放流来自不同进程，<br/>两者之间没有顺序保证——<br/>客户端不能假设"先收到响应再收到重放"
    Note over C,E: 续接完成，业务层无感
```

### 机器人客户端简化认证流程

```mermaid
sequenceDiagram
    participant RC as 机器人客户端
    participant A as Account服务
    participant R as Gate/逻辑节点

    Note over RC: 1. 从开发登录接口拿Token（代替OAuth）
    RC->>A: HTTP POST /dev_login<br/>{account: "robot1"}
    A-->>RC: {code, token}

    Note over RC: 2. 使用Token获取角色
    RC->>A: HTTP GET /roles<br/>Authorization: Bearer token
    A-->>RC: 返回角色列表

    alt 如果没有角色
        RC->>A: HTTP POST /create_role<br/>{server, name}
        A-->>RC: 返回新创建的角色
    end

    Note over RC: 3. 选择角色，取网关列表
    RC->>A: HTTP GET /gates
    A-->>RC: [{node, tcp_addr, ws_url, weight}]

    Note over RC: 4. 按 robot_transports 连 TCP 或 WS
    RC->>R: 建立连接
    R-->>RC: 连接建立成功

    RC->>R: sproto login.login<br/>{token, rid, proto_checksum, server}
    Note over R: 校验token，并确认rid属于token里的账号和区服，<br/>再经bind_session把会话绑定到实体所在节点
    R-->>RC: 登录响应<br/>{code, rid, nonce}

    RC->>R: sproto role.login_info
    R-->>RC: 角色信息响应

    Note over RC,R: 登录完成，开始游戏
```

## 关键数据结构

### JWT Token

**正式客户端**（通过 GamePass OAuth 获取）：

服务端 `jwt.verify_login`（`example/lualib/jwt.lua`）校验签名、`iss`、`aud` 和时效，业务代码仅使用 `account` 字段：

```json
{
  "account": "user_account_id",
  "iss": "skyext",
  "aud": "skyext-game",
  "iat": 1638360000,
  "exp": 1638360300
}
```

| 字段 | 说明 |
|------|------|
| iss / aud | 签发方与接收方，必须与 `login_jwt_issuer` / `login_jwt_audience` 一致。签名密钥只保证"是我们签的"，这两项保证"是这套服务签的、签给这套服务的"——同一密钥被别的系统或别的用途复用时不会互相串 |
| exp | **必填**，缺失直接拒绝：没有过期时间的登录 token 等于永久有效，一旦泄漏就收不回来。有效期由 `login_jwt_ttl` 决定 |
| iat / nbf | 可选。比较时都放宽 `login_jwt_leeway` 秒，容忍节点间时钟差 |

未知字段会被忽略。GamePass 这类外部签发方必须按上面的 `iss`/`aud` 签，否则服务端会拒绝。

**机器人客户端**（仅用于开发和测试）：向 Account 的 `POST /dev_login` 要 token，接口内部调用 `jwt.sign_login({ account = account })`。机器人自己不持有签名密钥。

`jwt.sign_login` 从配置取密钥和 `iss`/`aud`/`ttl`，自动补上 `iss`、`aud`、`iat`、`exp`。支持的签名算法：`HS256`、`HS512`。`/dev_login` 不校验身份，由 `dev_login_enable` 控制，正式环境必须关掉。

### nonce（续接凭据）

`login.login` 成功后下发，16 字节随机串。每次 `resume` 成功都会轮换一个新的，旧的立即失效——拿同一个 nonce 续接两次，第二次必然失败。客户端存在内存里即可，不需要落盘：进程重启之后实体多半也已经卸载了，续接不回来。

### Account 服务 API

登录 token 一律走 `Authorization: Bearer <token>` 请求头。放在 URL query 里会被写进访问日志和代理日志，等于把凭据明文留在一堆地方。

**网关列表：**

```
GET /gates

Response: { "code": 0, "gates": [{ "node": "gate1", "tcp_addr": "192.168.1.10:7052", "ws_url": "ws://192.168.1.10:7053", "weight": 1 }] }
```

> 不需要登录：这里只有地址，没有任何账号相关的东西。服务端也不替客户端"挑一台"——挑选策略（按区域、按版本、重试下一台）是客户端的事，服务端一旦代为选择，客户端就失去了换一台重试的能力，而这恰恰是断线续接最需要的。地址不要写死在客户端里。

**获取角色列表：**

```
GET /roles[?server=s1]
Authorization: Bearer <jwt_token>

Response: { "code": 0, "roles": [{ "rid": 1, "server": "s1", "name": "..." }] }
```

> `server` 参数可选，传入时仅返回该区服的角色。服务端通过区服目录校验区服是否存在。

**服务器列表：**

```
GET /servers

Response: { "code": 0, "servers": [{ "server": "s1", "name": "一区", "tag": "S1", "status": "open", "open_time": 1700000000, "recommended": true }] }
```

**创建角色：**

```
POST /create_role
Authorization: Bearer <jwt_token>
Body: { "server": "s1", "name": "角色名称" }

Response: { "code": 0, "role": { "rid": 1, "server": "s1", "name": "..." } }
```

> 只能在 `status = "open"` 的服建角；名字在出生服内唯一，重名返回 `NAME_TAKEN`。`max_role_count`（示例为 5）是单个区服的角色上限。

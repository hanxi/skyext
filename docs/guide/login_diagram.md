# 登录流程图

## 概述

系统支持两种认证方式：

1. **正式客户端 OAuth 认证**：通过 GamePass OAuth 服务进行用户身份认证，获取 JWT Token
2. **机器人客户端模拟认证**：机器人客户端直接生成 JWT Token，跳过 OAuth 流程

> **传输协议说明**：skynet gate 监听的是 TCP 端口。正式客户端通常经 WebSocket 网关（如 [goscon](https://github.com/hanxi/goscon)）转接到 TCP；机器人客户端使用 `socket.open` 直连 TCP。以下流程图中"连接到网关"均指最终到达 skynet gate 的连接。

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

    H --> I[HTTP GET /roles?token=xxx<br/>向Account服务获取角色列表]

    I --> J{是否有角色?}

    J -->|有角色| K[从角色列表中选择角色]
    J -->|无角色| L[HTTP POST /create_role<br/>创建新角色]

    L --> M{创建成功?}
    M -->|成功| N[获取新创建的角色信息]
    M -->|失败| O[登录失败]

    N --> K
    K --> P[经WebSocket网关连接到任意一个gate<br/>客户端不需要知道角色实体在哪个节点]

    P --> S{连接成功?}
    S -->|失败| T[连接失败]
    S -->|成功| U[发送sproto login.login消息<br/>包含token, rid, proto_checksum, server]

    U --> V{登录成功?}
    V -->|失败| W[登录失败]
    V -->|成功| X[发送sproto role.login_info消息]

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
```

## 机器人客户端简化流程

```mermaid
flowchart TD
    A1[机器人客户端启动] --> B1[HTTP POST /dev_login<br/>开发接口按账号名签发Token]
    B1 --> C1[HTTP GET /roles?token=xxx<br/>向Account服务获取角色列表]

    C1 --> D1{是否有角色?}

    D1 -->|有角色| E1[从角色列表中选择角色]
    D1 -->|无角色| F1[HTTP POST /create_role<br/>创建新角色]

    F1 --> G1{创建成功?}
    G1 -->|成功| H1[获取新创建的角色信息]
    G1 -->|失败| I1[登录失败]

    H1 --> E1
    E1 --> J1[从gate_addrs里依次试到第一个连得上的gate<br/>gate不必和角色实体在同一节点]
    J1 --> L1[TCP直连到gate]

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
        LocalGen[本地Token生成]
    end

    Client -->|OAuth认证| GamePass
    GamePass -->|返回JWT Token| Client
    RobotClient -->|直接生成| LocalGen
    LocalGen -->|模拟Token| RobotClient

    style GamePass fill:#e3f2fd
    style LocalGen fill:#fff3e0
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
        GateR1[rolenode1 同进程 gate<br/>:7012]
        GateR2[rolenode2 同进程 gate<br/>:7022]
        Gate1[独立网关节点 gate1<br/>:7052]
    end

    subgraph "逻辑节点池（不按区服划分，承载 role/rank 等实体）"
        RoleNode1[rolenode1]
        RoleNode2[rolenode2]
    end

    Client -->|HTTP 服务器列表/建角| Account1
    Client -->|连任意一个 gate| GateR1
    Client --> GateR2
    Client --> Gate1

    GateR1 -->|会话亲和转发| RoleNode1
    GateR1 --> RoleNode2
    GateR2 --> RoleNode1
    GateR2 --> RoleNode2
    Gate1 -->|跨节点转发| RoleNode1
    Gate1 -->|跨节点转发| RoleNode2

    style Account1 fill:#e8f5e8
    style Account2 fill:#e8f5e8
    style Gate1 fill:#e3f2fd
    style RoleNode1 fill:#fff3e0
    style RoleNode2 fill:#fff3e0
```

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
    C->>A: HTTP GET /roles?token=xxx
    A-->>C: 返回角色列表

    alt 如果没有角色
        C->>A: HTTP POST /create_role
        A-->>C: 返回新创建的角色
    end

    Note over C: 3. 选择角色，连接网关
    C->>R: 经WebSocket网关连接到任意一个gate
    R-->>C: 连接建立成功

    C->>R: sproto login.login<br/>{token, rid, proto_checksum, server}
    Note over R: 校验token，确认rid属于token里的账号和区服，<br/>再经bind_session把会话绑定到实体所在节点
    R-->>C: 登录响应<br/>{code, rid}

    C->>R: sproto role.login_info
    R-->>C: 角色信息响应

    Note over C,R: 登录完成，开始游戏
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
    RC->>A: HTTP GET /roles?token=xxx
    A-->>RC: 返回角色列表

    alt 如果没有角色
        RC->>A: HTTP POST /create_role<br/>{token, server, name}
        A-->>RC: 返回新创建的角色
    end

    Note over RC: 3. 选择角色，TCP直连网关
    RC->>R: TCP socket.open 连接到任意一个gate
    R-->>RC: 连接建立成功

    RC->>R: sproto login.login<br/>{token, rid, proto_checksum, server}
    Note over R: 校验token，并确认rid属于token里的账号和区服，<br/>再经bind_session把会话绑定到实体所在节点
    R-->>RC: 登录响应<br/>{code, rid}

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

### Account 服务 API

**获取角色列表：**

```
GET /roles?token=jwt_token_string[&server=s1]

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
Body: { "token": "...", "server": "s1", "name": "角色名称" }

Response: { "code": 0, "role": { "rid": 1, "server": "s1", "name": "..." } }
```

> 只能在 `status = "open"` 的服建角；名字在出生服内唯一，重名返回 `NAME_TAKEN`。`max_role_count`（示例为 5）是单个区服的角色上限。

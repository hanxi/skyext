# 归档

已经落地的规划与设计记录。内容停留在写作当时：其中的「现状」「要改的文件」「待办」描述的是实现之前的样子，**不代表当前行为**。当前行为以 `docs/guide/` 的使用指南和代码为准。

保留它们是为了决策背景，以后改这块代码时可以知道当初为什么这么取舍、排除过哪些方案。

| 文档 | 主题 | 现行文档 |
| --- | --- | --- |
| [session_resume.md](session_resume.md) | 会话续接与 WS/WSS 原生接入：包级续接、凭据轮换、下行重放、goscon 移出默认链路 | [登录流程](../guide/login.md)、[客户端接入规范](../guide/client_protocol.md) |
| [client_sdk_plan.md](client_sdk_plan.md) | 客户端 SDK（Lua + TypeScript）实施规划：nonce 改 `binary`、int64 用 `bigint`、vendor sproto-js 的补丁 | [客户端 SDK](../guide/client_sdk.md)、[完整客户端联调](../guide/fullstack_client.md) |

本目录与 `design/`、`plan/` 一样，不发布到在线文档站。

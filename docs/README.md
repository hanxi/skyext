# skyext 文档

skyext 是基于 [skynet](https://github.com/cloudwu/skynet) 的分布式游戏服务器框架。引擎提供通用服务与开发工具，`example/` 展示 Account、Role 与 Robot 节点的组织方式。项目仍在开发中；示例配置适合本地体验，不应直接部署到生产环境。

## 从哪里开始

1. [快速上手](getting-started.md)：准备依赖，构建并启动示例，运行测试。
2. [架构概览](overview.md)：理解引擎/游戏分层、节点职责与配置加载。
3. [不做的事](non-goals.md)：做过又删掉的设计，以及删它们的理由。
4. 根据需要进入下面的操作指南。

| 使用指南 | 内容 |
| --- | --- |
| [登录流程](guide/login.md) · [流程图](guide/login_diagram.md) | 客户端、Account 与 Role 的认证和交互 |
| [热更新操作](guide/hotfix.md) | 热更包、预演、执行与失败处理 |
| [GM HTTP API](guide/gm_api.md) | token 鉴权、命令查询与执行 |
| [HTTP 服务端](guide/http_server.md) | 命名实例、连接与超时上限、路由注册 |
| [指标采集与导出](guide/metrics.md) | counter/gauge/histogram 原语、Prometheus 抓取端点与内置指标 |
| [改 ORM schema](guide/orm_schema_change.md) | 运行期如何容忍字段增删、基线墓碑与不兼容改动的拦截 |

仓库另保存[实体系统设计](https://github.com/hanxi/skyext/blob/main/docs/design/entity_system.md)、[skytest 设计](https://github.com/hanxi/skyext/blob/main/docs/design/skytest.md)、[性能采样设计](https://github.com/hanxi/skyext/blob/main/docs/design/profiler.md)和[管理后台规划](https://github.com/hanxi/skyext/blob/main/docs/plan/admin_panel.md)。`design/`、`plan/` **不会部署到在线文档站**；这些链接指向 GitHub 源文件，且规划文档不代表功能已实现。

项目源码、Issue 与许可证见 [GitHub 仓库](https://github.com/hanxi/skyext)。

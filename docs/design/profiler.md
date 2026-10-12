# 火焰图采集服务

> **状态：原型阶段。** 已有 Lua 层采样原型（`lualib/skyext/profiler.lua`），含 GM 命令注册代码，但仓库内没有其他模块 `require "skyext.profiler"`，服务启动时默认不加载。原型的 hook 仅作用于采样协程，尚不能采集目标服务的业务调用栈。C 层跨服务采样方案（`lualib-src/profiler.c`、`service-src/service_profiler.c`）仅有骨架代码。优先级低于 Entity 系统和目录重构。

## 目标

为 skyext 引擎提供线上火焰图采集能力：对运行中的 skynet 服务进行低开销调用栈采样，生成 folded stack 格式数据，配合 FlameGraph 工具输出 SVG。

## 当前代码

### Lua 原型 — `lualib/skyext/profiler.lua`

提供 `M.start(target_service, duration, freq)` / `M.status(session_id)` / `M.result(session_id)` 三个 API，并在 `skynet.init` 中通过 `gm_api.register` 注册了 `profiler_start` / `profiler_status` / `profiler_result` GM 命令。

**已实现部分：**
- 会话管理（创建、查询、获取结果）
- `lua_sampler`：在 `skynet.fork` 创建的采样协程中设置 `debug.sethook(hook, "", 10000)`，等待 `skynet.sleep(duration * 100)` 后移除 hook。Lua hook 仅作用于该协程；协程睡眠时不运行其他业务协程，因此这个实现不能有效采样目标服务的工作负载
- 输出 folded stack 格式文本（`stack_a;stack_b count` 每行一条，可直接喂给 `flamegraph.pl`）

**未完成部分：**
- `target_service` 和 `freq` 参数虽然接收但未实际使用——当前 hook 只绑定采样协程，既不能覆盖本服务的其他业务协程，也无法采样其他 skynet 服务
- 采样频率固定为每 10000 条指令，与传入的 `freq` 参数无关
- 无处 `require "skyext.profiler"`，模块不会被加载

**接入方法**（仅用于研究原型）：在已启动 GM 服务的节点中，由要注册命令的 skynet 服务加载 `require "skyext.profiler"`。这会尝试注册 GM 命令，但传入的 `service` 不会控制采样位置；当前 hook 只绑定在采样协程，不能得到该服务其他业务协程或跨服务的有效火焰图。

### C 骨架

| 文件 | 类型 | 编译产物 | 当前状态 |
|------|------|----------|----------|
| `lualib-src/profiler.c` | Lua C 模块 | `luaclib/profiler_c.so` | `start()` 返回 `false` + 提示未实现 |
| `service-src/service_profiler.c` | skynet C 服务 | `cservice/profiler.so` | 加载时打印 "skeleton loaded"，不处理消息 |

两个文件均在 `build.mk` 中有编译目标，`make build` 可正常编译。

> 注：两个 C 源文件中的注释引用了 `docs/plans/profiler_design.md`，该路径不存在，实际即本文件 `docs/design/profiler.md`。

## 设计方向

Lua 原型搭起了会话管理、hook 及 folded stack 格式化的代码框架，但采样协程无法代表目标服务的业务调用栈，尚未验证有效火焰图。要采样其他 skynet 服务，需要重新设计采集方式，并评估是否使用 C 层能力。

### 目标架构

| 组件 | 职责 |
|------|------|
| `profiler.c`（Lua C 模块） | 注入目标服务的 Lua 状态，低开销采栈，C 侧哈希表聚合折叠栈 |
| `service_profiler.c`（C 服务） | 管理采样会话（开始/停止/频率），汇总多服务数据，输出 folded stack |

### 预期使用接口

沿用 Lua 原型已注册的 GM 命令格式：

```
# 开始采样：对指定服务采样 10 秒，频率 99Hz
POST /gm/execute  { "cmd": "profiler_start", "service": ".entity_agent:role:1", "duration": 10, "freq": 99 }

# 查询采样状态
GET  /gm/execute?cmd=profiler_status

# 获取结果：返回 folded stack 文本，可直接喂给 flamegraph.pl 生成 SVG
GET  /gm/execute?cmd=profiler_result&session_id=1
```

### 数据流

```
GM 命令 → service_profiler → 注入 debug hook 到目标 Lua 状态
  → C 侧采样 + 哈希表聚合 → 采样结束 → 返回 folded stack 文本
  → 可选：服务端调用 flamegraph.pl 生成 SVG，或返回原始数据由客户端处理
```

## 参考项目

实施前需研究以下项目，评估采样策略、性能影响和侵入性：

1. **skynet 火焰图的新方法** — https://spin6lock.github.io/2020/05/24/skynet%E7%81%AB%E7%84%B0%E5%9B%BE%E7%9A%84%E6%96%B0%E6%96%B9%E6%B3%95.html
2. **swt (skynet worker thread tools)** — https://github.com/lsg2020/swt
3. **skynet_systemtap_set** — https://github.com/chenweiqi/skynet_systemtap_set
4. **skynet-perf** — https://github.com/chenkete/skynet-perf

### 待评估要点

- 采样策略：debug hook vs signal-based vs SystemTap
- 性能开销目标：< 5% CPU
- 跨服务聚合方式
- 输出格式兼容性（folded stack → FlameGraph SVG）
- 是否需要修改 skynet 源码（侵入性评估）

## 验证标准

C 层方案完成后需满足以下条件：

1. 能对指定的其他 skynet 服务（非自身）启动定时采样
2. 采样期间目标服务 CPU 开销增加 < 5%
3. 返回的 folded stack 文本可被 `flamegraph.pl` 正确处理并生成 SVG
4. 通过 GM 命令完成完整采样流程（启动 → 等待 → 获取结果），无需 SSH 到服务器
5. 多次采样会话之间互不干扰

# 火焰图采集服务设计（待实现）

> 优先级：低。在 Entity 系统、Role 迁移、目录重构完成后再实施。

## 目标

为 skyext 引擎实现线上火焰图采集能力，支持对运行中的 skynet 服务进行低开销的调用栈采样，生成火焰图。

## 组件

| 组件 | 类型 | 职责 |
|------|------|------|
| `lualib-src/profiler.c` | C 模块 | 注入目标服务的 Lua 状态，低开销采栈 + C 侧哈希表聚合折叠栈 |
| `service-src/service_profiler.c` | C 服务 | 管理采样会话（开始/停止/采样频率），汇总多服务数据，输出 folded stack 格式 |

## 参考项目

1. **skynet 火焰图的新方法** — https://spin6lock.github.io/2020/05/24/skynet%E7%81%AB%E7%84%B0%E5%9B%BE%E7%9A%84%E6%96%B0%E6%96%B9%E6%B3%95.html
   - spin6lock 的博客，介绍 skynet 环境下生成火焰图的新方案

2. **swt (skynet worker thread tools)** — https://github.com/lsg2020/swt
   - lsg2020 的项目，skynet worker thread 级别的工具集

3. **skynet_systemtap_set** — https://github.com/chenweiqi/skynet_systemtap_set
   - chenweiqi 的项目，基于 SystemTap 的 skynet 诊断脚本集

4. **skynet-perf** — https://github.com/chenkete/skynet-perf
   - chenkete 的项目，skynet 性能分析工具

## 预期使用接口

通过 GM 命令触发采样，生成火焰图：

```
# 1. 开始采样：对指定服务采样 10 秒，采样频率 99Hz
POST /gm/execute
{ "cmd": "profiler_start", "service": ".roleagent:1", "duration": 10, "freq": 99 }

# 2. 查询采样状态
GET /gm/execute?cmd=profiler_status

# 3. 获取结果：返回 folded stack 文本，可直接喂给 FlameGraph 工具生成 SVG
GET /gm/execute?cmd=profiler_result&session_id=xxx
```

**数据流**：
```
GM 命令 → service_profiler(C 服务) → 注入 debug hook 到目标服务 Lua 状态
    → C 侧采样 + 哈希表聚合折叠栈 → 采样结束 → 返回 folded stack 文本
    → （可选）服务端调用 flamegraph.pl 生成 SVG，或返回原始数据由客户端生成
```

## 待研究

实施前需详细研究上述四个参考项目，评估：

- 采样策略：debug hook vs signal-based vs SystemTap
- 对目标服务的性能影响（目标：< 5% CPU 开销）
- 跨服务聚合方式
- 输出格式（folded stack → FlameGraph SVG）
- 是否需要修改 skynet 源码（侵入性）

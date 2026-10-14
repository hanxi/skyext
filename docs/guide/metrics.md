# 指标采集与导出

skyext 内置 counter / gauge / histogram 三种指标原语，节点上的 `metrics` 服务把各服务的指标合并后按 Prometheus 文本格式导出。

## 工作方式

每个 skynet 服务是独立的 Lua 虚拟机，指标先在本地累加——热路径上的自增是纯内存操作，不发消息。抓取时 `metrics` 服务才向注册过的服务各发一条 `collect_metrics`，把快照拉回来合并。

推模式每次自增都要发一条消息，热路径上扛不住，所以这里用拉模式。代价是抓取瞬间要跟每个服务通一次消息，因此抓取是并发的，并且带超时：

- 单个服务没在 `metrics_scrape_timeout` 内回包，这次抓取就不等它；
- 连续 3 次没回就把它摘掉。服务退出时不会（也不该指望它）来注销。

服务用 `skyext.cmd_api` 接管消息分发时就自动挂到 `.metrics` 上，业务代码不需要写初始化。队列积压、内存、CPU 这些运行时数据因此默认就可见，不用等业务先声明一个指标。

自己接管 `skynet.dispatch` 的服务挂不上去——它应答不了 `collect_metrics`，所以连运行时数据也没有。

## 声明和使用

```lua
local metrics = require "skyext.metrics"

-- 第三个参数是标签名数组，声明之后每次自增都必须把这些标签传全
local m_calls = metrics.counter("game_commands_total", "Commands handled", { "cmd" })
local m_online = metrics.gauge("game_online_players", "Players currently online")
local m_latency = metrics.histogram("game_command_seconds", "Command handling time", { "cmd" })

m_calls:inc(1, { cmd = "move" })
m_online:set(count)
m_latency:observe(0.012, { cmd = "move" })
```

| 原语 | 方法 | 用在哪 |
| --- | --- | --- |
| `metrics.counter(name, help, labels)` | `inc(value, labels)` | 只增不减的累计量，名字按约定以 `_total` 结尾 |
| `metrics.gauge(name, help, labels)` | `set/inc/dec(value, labels)` | 可上可下的瞬时值，比如在线数、连接数 |
| `metrics.histogram(name, help, labels, buckets)` | `observe(value, labels)` | 耗时和大小的分布，`buckets` 默认覆盖 5ms 到 10s |

几条约束是故意报错而不是容忍的：

- **漏传标签直接抛错。** 少一个标签会让两条本该分开的曲线悄悄叠在一起，这种数据错得无声无息。
- **counter 不能减。** 减了下游算出来的速率是错的。
- **同名指标类型或标签对不上会抛错。** 这说明是重名事故，不是复用。

标签的取值范围要有限。按玩家 ID、服务地址这类打标签会把时间序列数量打爆——需要区分来源时想清楚基数，默认用服务名这种收敛的维度。

## 抓取端点

`metrics` 服务监听独立端口，`GET /metrics` 返回文本格式：

```lua
metrics_http_host = "127.0.0.1" -- 默认 127.0.0.1
metrics_http_port = 9190 -- 默认 9091，按节点配，同机跑多个节点才不会撞
metrics_scrape_timeout = 300 -- 单次抓取等回包的时限，单位 1/100 秒
```

默认只听回环。这个端点**不鉴权**，暴露出去等于把内部拓扑和业务量公开，线上让 Prometheus 从同机或内网侧抓。

示例里 account1 / account2 / role1 / role2 分别用 9190 / 9191 / 9192 / 9193：

```sh
curl http://127.0.0.1:9190/metrics
```

GM 账号也可以走 `/gm/execute?cmd=metrics` 拿同一份文本，需要 `readonly` 及以上角色（见 [GM HTTP API](gm_api.md)）。

## 内置指标

节点起来就有的，不需要业务代码配合：

| 指标 | 类型 | 含义 |
| --- | --- | --- |
| `skynet_services` | gauge | 节点上运行的服务数 |
| `skynet_service_instances{service}` | gauge | 按服务名统计的实例数 |
| `skynet_service_mqlen{service}` | gauge | 消息队列积压，同名实例求和 |
| `skynet_service_mqlen_max{service}` | gauge | 积压最多的那个实例的队列长度 |
| `skynet_service_memory_bytes{service}` | gauge | Lua 堆占用 |
| `skynet_service_cpu_seconds_total{service}` | counter | 累计 CPU 时间 |
| `skynet_service_messages_total{service}` | counter | 累计处理的消息数 |
| `skyext_mongo_call_seconds{op}` | histogram | MongoDB 调用耗时，在调用方计时 |
| `skyext_mongo_call_errors_total{op}` | counter | 抛错的 MongoDB 调用数 |
| `skyext_http_connections{server}` | gauge | 正在处理的 HTTP 连接数 |
| `skyext_http_connections_rejected_total{server}` | counter | 因连接数上限被拒的连接 |
| `skyext_metrics_services` | gauge | 注册到 `.metrics` 的服务数 |
| `skyext_metrics_scrape_failures` | gauge | 本次抓取没回包的服务数 |
| `skyext_metrics_scrape_duration_seconds` | gauge | 本次抓取耗时 |

服务名取自 `.launcher`，并且会抹掉实例间的差异：`mongo_conn:center:1` 归到 `mongo_conn`，`http_agent_gm_2` 归到 `http_agent_gm`。不这么做的话服务一扩容时间序列就跟着涨。不是由 `.launcher` 拉起的服务（比如 skynet 自己启动的 logger）归到 `unknown`。

`mqlen` 同时给了求和与最大值：100 个服务各积 1 条和 1 个服务积 100 条，求和是一样的，但后者才是故障。

MongoDB 耗时在调用方计时，量到的是业务真正等了多久——既包含 mongo 的响应时间，也包含连接服务自身的排队。只看 mongo 侧耗时会把「连接数不够」这类问题漏掉。

## 合并规则

同名同标签的曲线一律相加。counter 相加是天然的；gauge 相加也正是想要的——4 个 dbmgr 各报 3 个脏实体，关心的是全节点有 12 个。`mqlen_max` 这类取最大值的指标单独处理。

两个服务用同一个名字声明了不同类型，或者直方图的桶边界不一致，合不了：丢掉后来的那一份，并记一条 ERROR 日志，而不是让数据莫名其妙少一半。

## Prometheus 配置

```yaml
scrape_configs:
  - job_name: skyext
    static_configs:
      - targets: ["127.0.0.1:9190"]
        labels: { node: account1 }
      - targets: ["127.0.0.1:9192"]
        labels: { node: role1 }
```

每个节点一个端点。节点名用 Prometheus 侧的 `labels` 打，不要在指标里自己拼。

# skytest 设计文档

## 背景

skyext 的质量工具统一为 `skytest` 模块（`lualib/skytest/`、`service/skytest_*.lua`、`scripts/commands/cov.lua`），包含测试框架和覆盖率工具。核心原则：**测试代码紧跟源码**。

## 决策

### 为什么不用 busted？

busted API 设计优秀，但有 3 个 C 模块依赖（luasystem、lua-term、LuaFileSystem），skyext 不使用 luarocks，引入成本过高。

> 注：busted 内部用 `xpcall` 包裹测试，Lua 5.5 的 `xpcall` 支持 yield，所以技术上能在 skynet 协程里工作。问题不是能不能跑，是依赖太重。

### 为什么整合而非分离？

覆盖率和测试总是配合使用。统一为 `skytest` 模块：
- 一个模块管所有质量工具
- 统一命名空间 `skytest`
- 一套路径配置
- 一个 README

### 测试紧跟代码

测试文件以 `.test.lua` 结尾，放在被测文件旁边：
- 测试直接 `require` 被测模块，调用函数验证结果
- 集成测试在 `before_all` 里用 `skynet.newservice()` 拉起依赖服务，全程一个进程
- `./bin/skyext test` 自动发现并运行所有 `.test.lua` 文件

### 每文件独立进程

每个 `.test.lua` 文件在独立的 skynet 进程中运行。`./bin/skyext test` 逐文件启动 skynet，每次只跑一个文件。

选择独立进程而非单进程顺序加载的原因：
- **完全隔离**：`skynet.setenv()` 只能调用一次（同 key 重复设置会抛错），独立进程让每个文件自由声明配置，互不冲突
- **无需清理**：进程退出自动释放所有资源（端口、服务、fd），不需要手动 kill service 或等待端口回收
- **与自包含原则一致**：一个文件 = 一个进程 = 配置 + 服务 + 断言，真正自包含
- **故障隔离**：一个文件 crash 不影响其他文件执行
- **开销可接受**：skynet 启动约 100-200ms，20 个文件多几秒，换来的隔离性远值得

### 为什么用 `.test.lua` 而不是 `_test.lua`？

Lua 的 `require` 把 `.` 当路径分隔符。`require "skyext.jwt.test"` 查找 `skyext/jwt/test.lua`，永远不会匹配 `skyext/jwt.test.lua`。所以 `.test.lua` 文件对 `require` 天然不可见，不可能被意外加载为模块。

### 伴生 `.test/` 目录

多数测试只需一个 `.test.lua` 文件。但 cluster 等多节点场景需要额外的 fixture 服务，而 skynet 的 `snlua` 从文件加载服务，无法内联在测试文件中。

约定：需要辅助资源时，创建与 `.test.lua` 同名的 `.test/` 目录：

```
lualib/skyext/cluster_rpc.lua               ← 源码
lualib/skyext/cluster_rpc.test.lua          ← 测试入口
lualib/skyext/cluster_rpc.test/             ← 测试资源目录（仅需要时创建）
    echo_service.lua                        ← fixture 服务
    proxy_service.lua                       ← fixture 服务
    cluster_nodes.json                      ← 测试数据
    init_data.lua                           ← 数据初始化脚本
```

`.test/` 目录同样对 `require` 不可见（原理同 `.test.lua`，见"为什么用 `.test.lua` 而不是 `_test.lua`？"）。

`ls` 天然分组：
```
cluster_rpc.lua
cluster_rpc.test.lua      ← 测试
cluster_rpc.test/          ← fixture（紧挨测试）
```

框架行为：
- `t.start_skynet()` 生成子进程 conf 时自动检查：若 `<name>.test/` 目录存在，追加到子进程的 `luaservice` 路径
- 测试代码直接用服务名启动 fixture：`t.start_skynet({ start = "echo_service" })`
- 测试代码内通过 `t.data_path("cluster_nodes.json")` 获取数据文件的绝对路径
- `./bin/skyext test` 只扫 `*.test.lua`，不会把 `.test/` 目录下的文件当测试执行
- 大多数测试没有 `.test/` 目录，零额外负担

生产环境隔离：`.test/` 目录**不会**出现在生产配置的搜索路径中。`paths.conf.lua` 仅包含 `lualib/`、`service/` 等标准路径，不含任何 `.test` 相关路径。`.test/` 目录的 `luaservice` 路径仅由 `t.start_skynet()` 追加到临时生成的子进程 conf 中，该 conf 仅用于测试，不影响生产 conf 文件。

## 命名规范

| 名称 | 说明 |
|------|------|
| `lualib/skytest/` | 框架与覆盖率 Lua 代码 |
| `lualib-src/skytest_hook.c` | C 加速 debug hook 源码 |
| `service/skytest_*.lua` | skytest 相关服务 |
| `scripts/commands/cov.lua` | 覆盖率 CLI 子命令（merge、check、summary、html） |
| `require "skytest"` | 测试框架入口，导出 describe/it/expect 等 API |
| `require "skytest.cov"` | 覆盖率入口 |
| `require "skytest.cov.install"` | hook 安装 + upvalue patching |
| `require "skytest.runner"` | 单文件测试执行引擎 |
| `require "skytest.expect"` | 断言库 |
| `require "skytest.reporter"` | 输出格式化 |
| `require "skytest.http"` | HTTP 测试助手 |
| `skytest_hook.c` | C 加速 debug hook |
| service `skytest_cov` | 覆盖率聚合服务 |
| `.skytest_cov` | 覆盖率服务注册名 |
| `skytest_runner` 服务 | 每个 skynet 进程的测试执行入口 |
| `./bin/skyext test` CLI | 发现 `*.test.lua`，逐文件启动 skynet 进程，汇总结果 |
| `SKYTEST_COV=1` | 启用覆盖率的环境变量 |
| `SKYTEST_COV_OUTPUT_DIR` | 覆盖率输出目录 |
| `SKYTEST_COV_SOURCE_DIRS` | 覆盖率源码目录 |
| `SKYTEST_COV_EXCLUDE` | 覆盖率排除模式 |
| `SKYTEST_COV_FLUSH_INTERVAL` | 覆盖率 flush 间隔 |
| `coverage/` | 覆盖率输出目录 |
| `[skytest.cov]` | 日志前缀 |
| `pcall(require, "skytest.cov")` | loader.lua 中的覆盖率加载 |

## 测试文件约定

测试文件以 `.test.lua` 结尾，放在被测文件同目录：

```
源码                                    测试
──────────────────────────────────────────────────────────
lualib/skyext/gm_router.lua            lualib/skyext/gm_router.test.lua
lualib/skyext/snowflake.lua            lualib/skyext/snowflake.test.lua
lualib/skyext/distributed_lock.lua     lualib/skyext/distributed_lock.test.lua
lualib/skyext/httpc.lua                lualib/skyext/httpc.test.lua
example/lualib/role_handler.lua        example/lualib/role_handler.test.lua
```

`ls` 输出天然有序：
```
gm_router.lua
gm_router.test.lua       ← 紧挨源码
snowflake.lua
snowflake.test.lua        ← 紧挨源码
```

规则：
1. 测试文件名 = 被测模块名 + `.test.lua`
2. 放在被测文件同目录
3. 对 `require` 不可见（原理见"为什么用 `.test.lua` 而不是 `_test.lua`？"）
4. `./bin/skyext test` 通过 glob `*.test.lua` 发现
5. 需要 fixture 服务时，创建同名 `.test/` 目录存放（见"伴生 `.test/` 目录"）

## 模块结构

skytest 已融入主项目结构，不再作为独立子目录：

```
lualib/skytest/                         # 框架与覆盖率 Lua 代码
├── init.lua                            # 框架入口：导出 describe/it/expect
├── runner.lua                          # 单文件测试执行引擎
├── expect.lua                          # 断言库
├── expect.test.lua                     # skytest 自测
├── reporter.lua                        # 输出格式化（mocha 风格）
├── http.lua                            # HTTP 测试助手
└── cov/
    ├── init.lua                        # 覆盖率入口
    ├── install.lua                     # hook 安装 + upvalue patching
    ├── collector.lua                   # 数据收集
    ├── config.lua                      # 配置（含 flush_interval 等）
    ├── lcov_reporter.lua               # lcov 报告生成
    └── source_lines.lua                # 源代码行扫描

lualib-src/skytest_hook.c               # C 加速 debug hook

service/skytest_cov.lua                 # 覆盖率聚合服务
service/skytest_runner.lua              # 测试运行器服务

scripts/                                # 统一 CLI（纯 Lua）
├── skyext.lua                          # CLI 入口
├── commands/
│   ├── test.lua                        # test 子命令（发现、执行、覆盖率）
│   ├── cov.lua                         # 覆盖率子命令（merge、check、summary、html）
│   └── ...                             # 其他子命令（serve、hotfix 等）
└── lib/
    └── lcov.lua                        # lcov 解析与合并库
```

## test CLI

```bash
# 运行所有测试（从项目根目录扫描）
./bin/skyext test

# 运行指定文件
./bin/skyext test lualib/skyext/snowflake.test.lua

# 运行指定目录
./bin/skyext test lualib/skyext/

# 按路径过滤（对完整相对路径做子串匹配，如 "snowflake" 匹配 lualib/skyext/snowflake.test.lua）
./bin/skyext test --match "snowflake"
# 可用路径前缀缩小范围：--match "skyext/snow" 不会匹配 example/ 下的同名文件
# 注：--match 过滤的是文件路径，不是 describe/it 名称（与 mocha --grep 不同）

# 带覆盖率
./bin/skyext test --cov

# 单文件超时（秒），默认 120
./bin/skyext test --timeout 60

# 指定 skynet 配置（极少需要，仅当自动生成的配置不满足时）
./bin/skyext test --conf custom.conf.lua
```

通常不需要 `--conf`：test 命令自动生成包含 paths 的基础配置，测试文件内通过 `skynet.setenv()` 声明业务配置。

> 注：生成的 conf 中 `game_root` 固定指向 `root .. "example/"`，这是 `paths.conf.lua` 约定的路径前缀——`paths.conf.lua` 用 `game_root` 拼接 `example/` 下的 lualib、service 等搜索路径。纯引擎层测试（`lualib/skyext/*.test.lua`）不依赖 `game_root` 下的文件，该值不会产生副作用；集成测试若需要 `example/` 下的服务则直接可用。如果项目结构变化（比如 `game_root` 不再是 `example/`），只需修改 `gen_conf` 中的这一行。

### 工作原理

test 命令完全用 Lua 实现（`scripts/commands/test.lua`），通过 `tool_process`（C 模块，`lualib-src/tool_process.c`）管理子进程。不依赖 bash 或 GNU coreutils。

步骤：
1. 扫描目标路径，收集所有 `*.test.lua` 文件
2. 生成临时 skynet 配置（或使用 `--conf`），include `paths.conf.lua` 复用项目路径
3. 逐文件启动独立 skynet 进程：调用 `tool_process.run({ binary, config }, { cwd, env, timeout })` 启动 `bin/skynet`，通过环境变量 `SKYTEST_FILE` 传递单个文件路径
4. 每个 skynet 进程启动 `skytest_runner` 服务
5. runner 用 `loadfile(os.getenv("SKYTEST_FILE"))` 加载该测试文件（完整相对路径，不走 `require`，避免污染 `package.loaded` 缓存）。`loadfile` 返回 nil 时（语法错误、文件不存在），输出错误信息并 `os.exit(2)`
6. 执行文件内所有 describe/it，输出 mocha 风格报告
7. 进程退出（`os.exit(0)` / `os.exit(1)` / `os.exit(2)`）
8. `tool_process` 的超时机制兜底，防止测试挂死（见"超时"一节）
9. 所有文件跑完后输出汇总

`--cov` 模式额外设置 `SKYTEST_COV=1`，每个进程独立写覆盖率数据到临时目录，跑完后由 `scripts/lib/lcov.lua` 在进程内合并。

## 测试框架 API

### 模块测试

直接 require 被测模块，调用函数验证：

```lua
-- lualib/skyext/snowflake.test.lua
local t = require "skytest"
local snowflake = require "skyext.snowflake"

t.describe("snowflake", function()

    t.it("generate unique ids", function()
        local gen = snowflake.new(1)
        local id1 = gen:next_id()
        local id2 = gen:next_id()
        t.expect(id1).to.be_type("number")
        t.expect(id2).to.be_type("number")
        t.expect(id1).to_not.equal(id2)
    end)

    t.it("different workers produce different ids", function()
        local g1 = snowflake.new(1)
        local g2 = snowflake.new(2)
        t.expect(g1:next_id()).to_not.equal(g2:next_id())
    end)
end)
```

### 集成测试（自包含）

每个文件运行在独立 skynet 进程中，可自由使用 `skynet.setenv()` 声明配置、`skynet.newservice()` 拉起服务，进程退出自动清理一切。不需要 `after_all` 手动 kill service：

```lua
-- lualib/skyext/gm_router.test.lua
local skynet = require "skynet"
local t = require "skytest"

t.describe("gm_router", function()

    -- 直接测模块逻辑
    t.it("unknown command returns error", function()
        local gm_router = require "skyext.gm_router"
        local r = gm_router.new()
        local result = r:dispatch("nonexistent", {})
        t.expect(result.error).to.exist()
    end)
end)

t.describe("gm HTTP integration", function()
    local GM
    local TOKEN = "test_token_" .. math.random(100000)

    t.before_all(function()
        skynet.setenv("gm_port", "19090")
        skynet.setenv("gm_token", TOKEN)

        skynet.newservice("gm_http")
        GM = "http://127.0.0.1:19090"
        t.wait_for_port(19090)
    end)

    t.it("无 token 返回错误", function()
        local _, body = t.http.get_json(GM, "/gm/list")
        t.expect(body.error).to.exist()
    end)

    for _, cmd in ipairs({"stat", "gc", "mem", "list", "ping", "netstat"}) do
        t.it(cmd .. " 命令成功", function()
            local status, body = t.http.get_json(GM,
                "/gm/execute?token=" .. TOKEN .. "&cmd=" .. cmd)
            t.expect(status).to.equal(200)
            t.expect(body.code).to.equal(0)
        end)
    end

    t.it("不存在的命令返回错误", function()
        local _, body = t.http.get_json(GM,
            "/gm/execute?token=" .. TOKEN .. "&cmd=nonexistent")
        t.expect(body.code).to_not.equal(0)
    end)

    t.it("POST JSON body 认证", function()
        local status, body = t.http.post_json(GM, "/gm/execute", {
            token = TOKEN, cmd = "stat"
        })
        t.expect(status).to.equal(200)
        t.expect(body.code).to.equal(0)
    end)

    t.it("Bearer token 认证", function()
        local status, body = t.http.request("POST", GM, "/gm/execute", {
            headers = { Authorization = "Bearer " .. TOKEN },
            json = { cmd = "gc" },
        })
        t.expect(status).to.equal(200)
        t.expect(body.code).to.equal(0)
    end)
end)
```

#### table 类型配置

`skynet.setenv()` 只接受字符串。对于 table 类型配置（如 `log_config`），使用 `skyext.config` 的序列化机制：

```lua
local config = require "skyext.config"

t.before_all(function()
    skynet.setenv("gm_port", "19090")
    skynet.setenv("log_config", config.serialize({
        { name = "console" },
    }))
    skynet.newservice("gm_http")
end)
```

服务端用 `config.get_table("log_config")` 读取，与生产环境一致。

> `config.lua` 中 `serialize` 导出为 `M.serialize(t)`。使用 `string.format("%q", t)` 处理字符串，自动转义所有特殊字符。

关键点：
- 每个文件独立进程，`skynet.setenv()` 随意用，不会跨文件冲突
- `skynet.newservice()` 在同一进程内启动服务，无需外部编排
- 进程退出自动释放所有端口和资源，不需要 `after_all` 手动清理服务
- `t.wait_for_port(port)` 等待服务就绪（内部轮询，超时报错）
- 覆盖率自动覆盖同进程所有代码（包括 newservice 加载的模块）
- 一个文件 = 一个进程 = 配置 + 服务启动 + 断言，完全自包含

运行：
```bash
./bin/skyext test lualib/skyext/gm_router.test.lua
```

### 多节点测试（cluster）

cluster 等多节点场景需要启动额外的 skynet 进程。框架提供 `t.start_skynet()` 助手：

```lua
-- lualib/skyext/cluster_rpc.test.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local t = require "skytest"

t.describe("cluster RPC", function()

    t.before_all(function()
        -- 当前进程作为 node_a
        skynet.setenv("cluster_name", "node_a")
        skynet.setenv("cluster_port", "19200")
        cluster.open("node_a")

        -- 启动独立 skynet 进程作为 node_b
        -- echo_service.lua 在 cluster_rpc.test/ 目录下，runner 自动加入 luaservice
        t.start_skynet({
            start = "echo_service",
            env = {
                cluster_name = "node_b",
                cluster_port = "19201",
            },
        })
        t.wait_for_port(19201)
    end)

    t.it("跨节点调用成功", function()
        local r = cluster.call("node_b", "echo_service", "echo", "hello")
        t.expect(r).to.equal("hello")
    end)

    t.it("节点不可达返回错误", function()
        t.expect(function()
            cluster.call("nonexistent", "svc", "cmd")
        end).to.throw()
    end)
end)
```

对应的 fixture 目录结构：
```
lualib/skyext/cluster_rpc.lua
lualib/skyext/cluster_rpc.test.lua
lualib/skyext/cluster_rpc.test/
    echo_service.lua                    ← fixture 服务
```

多数 cluster 测试的远端节点直接启动已有的生产服务（如 `gm_http`），不需要 fixture。仅当需要测试专用的轻量服务时才用 `.test/` 目录。

`t.start_skynet(opts)` 内部：
1. 生成临时 conf（复用 `paths.conf.lua`，注入 `opts.env` 和 `opts.start`）
2. 若 `.test/` 目录存在，追加到 conf 的 `luaservice`
3. 通过 `tool_process.spawn` 启动 `bin/skynet tmp.conf`，获取子进程句柄
4. 句柄和临时 conf 路径注册到清理列表（清理机制见"执行模型 → 子进程生命周期"）
5. 返回子进程 PID（`child:id()`）

### 断言 API

所有断言同时支持 `to` 和 `to_not` 两种形式：

```lua
-- 相等（深度比较，表递归）
t.expect(value).to.equal(expected)
t.expect(value).to_not.equal(expected)

-- 存在性
t.expect(value).to.exist()                  -- value ~= nil（仅排除 nil，false 会通过）
t.expect(value).to.be_nil()                 -- value == nil
t.expect(value).to.be_truthy()              -- value ~= nil and value ~= false
t.expect(value).to.be_falsy()               -- value == nil or value == false

-- 类型
t.expect(value).to.be_type("string")

-- 比较
t.expect(value).to.be_gt(n)                -- >
t.expect(value).to.be_gte(n)               -- >=
t.expect(value).to.be_lt(n)                -- <
t.expect(value).to.be_lte(n)               -- <=

-- 字符串
t.expect(str).to.contain("substr")
t.expect(str).to.match("pattern")          -- Lua pattern 匹配

-- 表
t.expect(tbl).to.have_key("key")
t.expect(tbl).to.have_length(n)

-- 异常
t.expect(fn).to.throw()
t.expect(fn).to.throw("pattern")           -- error message 需匹配此 Lua pattern
```

### HTTP 助手

基于 `skyext.httpc`，自动 JSON 编解码：

```lua
local status, body = t.http.get(host, path)                    -- GET 原始响应
local status, body = t.http.get_json(host, path)                -- GET + JSON decode
local status, body = t.http.post(host, path, data, ctype)       -- POST 原始
local status, body = t.http.post_json(host, path, tbl)          -- POST JSON + decode
local status, body = t.http.request(method, host, path, opts)   -- 通用请求
-- opts: { headers = {}, json = {}, body = "", timeout = 5 }
```

> 注：`http.lua` 依赖 `skyext.httpc`，即测试框架依赖被测项目的 HTTP 客户端。这是有意的取舍——避免引入外部 HTTP 依赖，代价是 `httpc` 本身有 bug 时 HTTP 测试助手也受影响。如果未来发现 httpc bug 导致测试框架不可信，备选方案是在 `skytest.http` 内置一个最小的 socket + HTTP/1.1 实现（仅支持 GET/POST + Content-Length，几十行 Lua，不走 skynet 异步 HTTP）。

错误行为：
- 连接失败（服务未启动、端口未监听）：抛异常（`error()`），测试标记为失败。因此应在 `before_all` 中用 `t.wait_for_port()` 确保服务就绪后再调用 HTTP 助手。
- HTTP 错误状态码（4xx/5xx）：**不**抛异常，正常返回 `status, body`，由测试用断言检查。这是有意的——很多测试需要验证错误响应。
- `opts.timeout`：请求级超时（秒），默认 5。超时后抛异常。

### 工具函数

```lua
t.wait_for_port(port, timeout)              -- 等待端口可连接，默认超时 5 秒
-- 内部每 50ms 尝试 TCP connect，超时后抛异常（error()），不返回 false。
-- 在 before_all 中调用时，异常会导致该 describe 下所有 it 被跳过并标记失败。

t.start_skynet(opts)                        -- 启动子 skynet 进程（见"多节点测试"），返回子进程 PID
-- opts: { start = "服务名", env = { key = "value" } }
-- 内部通过 tool_process.spawn 启动，句柄注册到清理列表。
-- 启动失败（如 conf 生成错误）立即抛异常。
-- t._cleanup() 在退出前调用 child:close()（SIGTERM → SIGKILL）并删除临时 conf。

t.data_path(filename)                       -- 返回 .test/ 目录下文件的绝对路径
-- 根据当前测试文件路径推算：若测试文件为 foo.test.lua，则返回 foo.test/<filename> 的绝对路径。
-- 文件不存在时不报错，由调用方 io.open 后自行处理。
```

### 生命周期

```lua
t.describe("group", function()
    t.before_all(function()  end)    -- 组开始前执行一次（启动服务）
    t.after_all(function()  end)     -- 组结束后执行一次（可选清理）
    t.before_each(function() end)    -- 每个 it 前执行
    t.after_each(function()  end)    -- 每个 it 后执行

    t.it("test", function() end)

    t.describe("nested", function()  -- 支持嵌套
        t.it("nested test", function() end)
    end)
end)
```

> `after_all` 在独立进程模型下是可选的——进程退出自动清理所有资源。仅当需要在同文件后续 describe 之前释放资源（如端口）时才需要。

异常行为：
- `before_all` 抛异常：该 `describe` 下所有 `it` 被跳过，每个 `it` 标记为失败并显示 `before_all` 的错误信息。`after_all` 不执行。最终退出码为 1。
- `before_each` 抛异常：当前 `it` 标记为失败，后续 `it` 继续执行（各自独立调用 `before_each`）。
- `after_each` / `after_all` 抛异常：记录错误，不影响已通过的 `it` 结果，但文件退出码变为 1。
- `it` 内抛异常（含断言失败）：当前 `it` 标记为失败，后续 `it` 继续执行。

### 输出格式（mocha 风格）

单文件输出：
```
  snowflake
    ✓ generate unique ids (0ms)
    ✓ different workers produce different ids (0ms)

  2 passing (1ms)
```

`./bin/skyext test` 流式输出各文件结果，最后汇总：
```
▶ lualib/skyext/snowflake.test.lua
  snowflake
    ✓ generate unique ids (0ms)
    ✓ different workers produce different ids (0ms)

  2 passing (1ms)

▶ lualib/skyext/gm_router.test.lua
  gm_router
    ✓ unknown command returns error (0ms)

  gm HTTP integration
    ✓ 无 token 返回错误 (3ms)
    ✓ stat 命令成功 (2ms)
    ✓ gc 命令成功 (1ms)
    ✗ mem 命令成功 (2ms)
      Expected body.code to equal 0, got 1
      at lualib/skyext/gm_router.test.lua:45

  5 passing (8ms)
  1 failing

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2 files, 7 passing, 1 failing

Failed:
  lualib/skyext/gm_router.test.lua
```

## 执行模型

### 每文件独立进程

`./bin/skyext test` 为每个 `.test.lua` 文件启动一个独立的 skynet 进程：

```
./bin/skyext test lualib/skyext/
  │
  ├─ 扫描 *.test.lua → [snowflake.test.lua, gm_router.test.lua, ...]
  │
  ├─ 文件 1: SKYTEST_FILE=lualib/skyext/snowflake.test.lua  ./bin/skynet $CONF
  │   └─ skynet 进程（独立）
  │       └─ skytest_runner
  │           ├─ local file = os.getenv("SKYTEST_FILE")
  │           ├─ loadfile(file)  -- 完整相对路径，非 require
  │           ├─ 执行 describe/it
  │           ├─ 输出报告
  │           └─ os.exit(0)  ← 进程结束，一切自动释放
  │
  ├─ 文件 2: SKYTEST_FILE=lualib/skyext/gm_router.test.lua  ./bin/skynet $CONF
  │   └─ skynet 进程（独立）
  │       └─ skytest_runner
  │           ├─ loadfile(file)  -- 同上，完整相对路径
  │           ├─ before_all: skynet.setenv() + skynet.newservice("gm_http")
  │           ├─ 执行 describe/it
  │           ├─ 输出报告
  │           └─ os.exit(1)  ← 进程结束，gm_http 服务 + 端口自动释放
  │
  └─ 汇总：2 files, 7 passing, 1 failing
```

每个进程完全独立：
- 独享 `skynet.setenv` 命名空间，无冲突
- 服务和端口随进程退出自动释放
- 一个文件 crash 不影响其他文件
- `tool_process` 超时机制兜底挂死的测试

### skynet 协程

每个 skynet 进程内，测试运行在 `skytest_runner` 服务的 `skynet.start` 回调中。每个 `it()` 用 `xpcall` 包裹执行（Lua 5.5 的 `xpcall` 支持 yield），因此测试内可以自由调用 `skynet.call`、`skynet.sleep`、`skynet.newservice`、`t.http.*` 等异步操作。

### `SKYTEST_FILE` 环境变量

`skytest_runner` 通过 `os.getenv("SKYTEST_FILE")` 读取待执行的测试文件路径（OS 环境变量，非 `skynet.getenv`）。

### 退出码

| 场景 | 退出码 |
|------|--------|
| 所有测试通过 | 0 |
| 有测试失败（含 `before_all`/`before_each` 抛异常） | 1 |
| 文件加载失败（语法错误、文件不存在、`loadfile` 返回 nil） | 2 |

单文件 skynet 进程的退出码 1 和 2 的区别：2 表示文件无法加载为 Lua chunk 或顶层执行出错，测试尚未开始；1 表示测试运行期间有失败——包括断言失败、`before_all` 中 `skynet.newservice()` 抛异常、`t.wait_for_port()` 超时等。`before_all` 异常会导致该 `describe` 下所有 `it` 被跳过并标记为失败。统一 CLI 汇总所有文件后，任何失败或加载错误都会返回 1。

`skytest_runner` 完成后调用 `os.exit(code)`。test 命令汇总所有文件的退出码，任何文件非 0 则最终退出码非 0。

### 超时

test 命令通过 `tool_process` 为每个 skynet 进程设置超时（默认 120 秒，`--timeout` 覆盖）。`tool_process` 将子进程放入独立进程组（`setpgid`），超时后向整个进程组发 SIGTERM，5 秒内未退出则 SIGKILL，该文件计为失败（退出码 124）。

不在 skynet 层实现 per-test 超时——per-file 进程级超时更简单可靠，且能兜住 skynet 本身挂死的情况。

### 子进程生命周期

`t.start_skynet()` 启动的子 skynet 进程有三层清理保障，从内到外：

1. **Lua 层（正常退出）**：`t.start_skynet()` 将子进程句柄注册到清理列表。`skytest_runner` 退出前调用 `t._cleanup()`，遍历列表对每个句柄调用 `child:close()`（发送 SIGTERM，超时后 SIGKILL，等待退出），并删除临时 conf 文件。覆盖正常通过和断言失败的场景。

2. **GC 兜底**：如果句柄在进程运行期间被 GC，`tool_process.child` 的 `__gc` 元方法会调用 `close()`；进程直接崩溃时不能依赖 GC，仍需要第 3 层兜底。

3. **tool_process.run 层（外层兜底）**：test 命令通过 `tool_process.run()` 启动每个测试的 skynet 主进程，并将其放入独立进程组（`setpgid`）。超时后向整个进程组发 SIGTERM，5 秒内未退出则 SIGKILL。`t.start_skynet()` 通过 `tool_process.spawn` 启动的子进程继承同一进程组，因此也会被一并终止。

正常流程走第 1 层，极端情况走第 2 或第 3 层。各层之间没有竞争——第 1 层在进程内完成，第 3 层在进程外触发。

### 串行执行

当前版本逐文件串行执行。选择串行的原因：
- 输出不交错，报告可读
- 端口冲突风险为零（无需全局端口分配）
- 实现简单，逻辑直白
- skynet 启动约 100-200ms，20 个文件总开销约 2-4 秒，串行开销可接受

未来如果文件数增长到影响 CI 时间（> 2 分钟），可加 `-j N` 并行选项：每个文件已经是独立进程，天然可并行。实现时需要解决两个问题：（1）输出缓冲——每个文件的 stdout 写到临时文件，完成后按序输出；（2）端口冲突——集成测试文件需要分配不同端口，通过环境变量 `SKYTEST_PORT_BASE` 传入基准端口，由框架自动偏移。当前版本不做这些。

### 测试隔离

- **文件间**：每个文件独立 skynet 进程，天然完全隔离
- **文件内**：`it` 顺序执行，共享 `before_all` 建立的上下文
- 测试文件通过 `loadfile` 加载（非 `require`），不进入 `package.loaded` 缓存。`loadfile` 的工作目录是项目根目录（`tool_process.run` 通过 `cwd` 参数设定），因此 `SKYTEST_FILE` 的相对路径（如 `lualib/skyext/snowflake.test.lua`）可直接传入

### 覆盖率

`--cov` 模式下：
- 每个 skynet 进程设置 `SKYTEST_COV=1`
- `skytest.cov` 的 debug hook 捕获同进程内所有代码的执行（包括 `newservice` 加载的服务代码）
- `t.start_skynet()` 启动的子进程继承 `SKYTEST_COV=1` 环境变量，子进程也会独立写覆盖率数据
- 每个进程独立写覆盖率数据到本次运行的临时目录（文件名含 PID，避免冲突），合并结果写入 `coverage/`
- 所有文件跑完后，test 命令通过 `scripts/lib/lcov.lua` 在进程内合并各进程的 lcov 数据
- `SKYTEST_COV_FLUSH_INTERVAL`：覆盖率数据自动 flush 间隔（秒），默认 10。在 `skytest.cov.config` 中读取，传给 collector 定时写盘

## 相关外部文件

### `lualib/skyext/config.lua`

`serialize` 导出为 `M.serialize(t)`，供测试文件序列化 table 配置。使用 `string.format("%q", t)` 处理字符串转义。

### `lualib/loader.lua`

```lua
pcall(require, "skytest.cov")  -- skytest 覆盖率
```

### `build.mk`

编译 target：
```makefile
$(SKYEXT_LUACLIB_PATH)/skytest/hook.so : $(SKYEXT_ROOT)/lualib-src/skytest_hook.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)
```

### `example/etc/paths.conf.lua`

skytest 的 Lua 代码和服务已融入主项目的 `lualib/` 和 `service/` 目录，无需额外路径配置——标准搜索路径已覆盖：

```lua
lua_path = lua_path .. skyext_root .. "lualib/?.lua;"
lua_path = lua_path .. skyext_root .. "lualib/?/init.lua;"
luaservice = luaservice .. skyext_root .. "service/?.lua;"
```

### 覆盖率集成

覆盖率功能已集成到 `./bin/skyext test --cov`，不再需要独立脚本。

### `.github/workflows/coverage.yml`

核心流程为 `./bin/skyext test --cov`。CI 环境下外部服务地址通过 OS 环境变量注入：

```yaml
    - name: Run tests with coverage
      run: ./bin/lua scripts/skyext.lua test --cov
      env:
        MONGO_HOST: mongo
        ETCD_ENDPOINTS: http://etcd:2379
```

### `.gitignore`

```
coverage/
```

## 补充约定

### 错误信息格式

`skytest_runner` 输出统一前缀 `[skytest]`，便于 CI 日志过滤：

- `SKYTEST_FILE` 未设置：`[skytest] ERROR: SKYTEST_FILE not set`，`os.exit(2)`
- 文件不存在 / 语法错误：`[skytest] ERROR: failed to load <path>: <message>`，`os.exit(2)`
- `before_all` 异常：`[skytest] ERROR: before_all failed: <message>`，该 describe 下所有 it 标记失败

### 平台支持

test CLI 用 Lua 编写，通过 `tool_process`（C 模块）管理子进程和超时，不依赖 bash 或 GNU coreutils。POSIX 平台使用 `fork`/`execvp`、`posix_spawnp`、进程组与 `waitpid`；Windows 使用 `CreateProcessW` 和 Job Object。Linux 已验证，macOS、FreeBSD 和 Windows 有构建目标，但尚需在目标平台执行测试。

### 多 describe 支持

一个 `.test.lua` 文件内支持多个平级 `t.describe()`（如 gm_router 示例中的"gm_router"和"gm HTTP integration"）。它们按声明顺序执行，共享文件级的 skynet 进程，但各自的 `before_all` / `after_all` 独立。

## 验证

1. `make build` — 编译通过（产物在 `luaclib/skytest/hook.so`）
2. `./bin/skyext test lualib/skyext/errcode.test.lua` — 单文件模块测试通过
3. `./bin/skyext test lualib/skyext/` — 目录级测试通过，逐文件输出 mocha 风格报告 + 汇总
4. `./bin/skyext test --cov lualib/skyext/` — 带覆盖率的测试，各进程独立写 lcov，合并后生成报告
5. `./bin/skyext test lualib/skytest/process.test.lua` — fixture 集成测试启动子 skynet 并验证可连接
6. `./bin/skyext test --cov` — 完整覆盖率流程
7. 故意写一个失败测试 → test 命令退出码为 1
8. 故意写一个语法错误的测试文件 → 单文件 skynet 进程退出码为 2，统一 CLI 退出码为 1，报告指出错误文件
9. 故意写一个死循环测试 → `tool_process` 超时生效，文件计为失败，后续文件正常执行
10. fixture 子进程测试 → `t.start_skynet` 启动子进程，测试完成后 `child:close()` 清理；进程异常退出则由外层进程组兜底

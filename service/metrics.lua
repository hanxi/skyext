-- 指标采集服务：抓取时把各服务本地累加的指标拉过来合并，按 Prometheus 文本格式导出。
--
-- 拉模式而不是推模式：热路径上的自增必须是纯内存操作，不能每次都发消息。
-- 代价是抓取时要跟每个注册过的服务通一次消息，所以这里用并发请求 + 超时，
-- 单个服务卡住不会把整次抓取拖死。
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local log = require "skyext.log"
local merge = require "skyext.metrics_merge"
local metrics_text = require "skyext.metrics_text"
local http_server = require "skyext.http_server"
local gm_api = require "skyext.gm_api"

local CMD = {}

-- addr -> { fails = n }
local g_services = {}
-- 连续失败这么多次就摘掉：服务已经退出时不该让它一直拖着每次抓取的超时
local MAX_FAILS = 3

local g_scrape_timeout -- 单位 1/100 秒

local function scrape_timeout()
    if not g_scrape_timeout then
        g_scrape_timeout = config.get_number("metrics_scrape_timeout") or 300
    end
    return g_scrape_timeout
end

-- 从 launcher 的描述里取出服务名，并抹掉实例间的差异。
--
-- 描述形如 "snlua gm"、"snlua service_cell http_agent_gm_2"、
-- "snlua mongo_conn:center:1 center 1"。带实例编号的名字必须归一，否则
-- 8 个 mongo_conn 就是 8 条曲线，服务一扩容时间序列就跟着涨。
local function parse_service_name(desc)
    local name = desc:match("^%S+%s+(%S+)") or desc
    -- service_provider 起的服务套了一层 service_cell，真名在后一段
    if name == "service_cell" then
        name = desc:match("^%S+%s+service_cell%s+(%S+)") or name
    end
    -- "mongo_conn:center:1" -> "mongo_conn"
    name = name:match("^([^:]+)") or name
    -- "http_agent_gm_2" -> "http_agent_gm"
    return (name:gsub("_%d+$", ""))
end

-- 地址 -> 服务名。launcher 的 LIST 只读它自己的表，不会扇出到各个服务，很便宜。
local function service_names()
    local ok, list = pcall(skynet.call, ".launcher", "lua", "LIST")
    if not ok then
        log.warn("metrics cannot list services", "err", tostring(list))
        return {}, 0
    end
    local names = {}
    local total = 0
    for addr, desc in pairs(list) do
        names[addr] = parse_service_name(desc)
        total = total + 1
    end
    return names, total
end

local function collect_runtime(acc, name, runtime)
    if type(runtime) ~= "table" then
        return
    end
    local labels = { service = name }
    acc:add("skynet_service_instances", "Number of running instances per service name", "gauge", labels, 1)
    acc:add("skynet_service_mqlen", "Pending messages summed over instances", "gauge", labels, runtime.mqlen or 0)
    -- 总和看不出积压集中在哪：100 个服务各积 1 条和 1 个服务积 100 条，总和一样
    acc:max("skynet_service_mqlen_max", "Pending messages of the most backed up instance", labels, runtime.mqlen or 0)
    acc:add("skynet_service_memory_bytes", "Lua heap in use", "gauge", labels, runtime.memory or 0)
    acc:add("skynet_service_cpu_seconds_total", "CPU time consumed", "counter", labels, runtime.cpu or 0)
    acc:add("skynet_service_messages_total", "Messages processed", "counter", labels, runtime.message or 0)
end

-- 拉一轮，返回合并后的快照
local function scrape()
    local started = skynet.hpc()
    local names, total_services = service_names()

    local req = skynet.request()
    local addrs = {}
    local registered = 0
    for addr in pairs(g_services) do
        local entry = { addr, "lua", "collect_metrics" }
        req:add(entry)
        addrs[entry] = addr
        registered = registered + 1
    end

    local acc = merge.new()
    local answered = {}
    if registered > 0 then
        for entry, resp in req:select(scrape_timeout()) do
            local addr = addrs[entry]
            local payload = resp and resp[1]
            if type(payload) == "table" then
                answered[addr] = true
                acc:add_snapshot(payload.metrics)
                collect_runtime(acc, names[skynet.address(addr)] or "unknown", payload.runtime)
            end
        end
    end

    local failed = 0
    for addr, state in pairs(g_services) do
        if answered[addr] then
            state.fails = 0
        else
            failed = failed + 1
            state.fails = state.fails + 1
            if state.fails >= MAX_FAILS then
                -- 服务退出时没人来注销（也不该指望它），这里自己摘
                log.info("metrics service unresponsive, dropped", "service", skynet.address(addr))
                g_services[addr] = nil
            end
        end
    end

    acc:add("skyext_metrics_services", "Services registered for metrics collection", "gauge", nil, registered)
    acc:add("skyext_metrics_scrape_failures", "Services that did not answer this scrape", "gauge", nil, failed)
    acc:add("skynet_services", "Services running in this node", "gauge", nil, total_services)
    acc:add(
        "skyext_metrics_scrape_duration_seconds",
        "Time the last scrape took",
        "gauge",
        nil,
        (skynet.hpc() - started) / 1e9
    )

    local snapshot, conflicts = acc:result()
    if conflicts then
        -- 同名不同类型的指标只能丢掉一边，不报出来会变成"数据莫名其妙少了一半"
        log.error("metrics name conflict, samples dropped", "names", table.concat(conflicts, ","))
    end
    return snapshot
end

function CMD.register_service(addr)
    if not g_services[addr] then
        g_services[addr] = { fails = 0 }
        log.info("metrics service registered", "service", skynet.address(addr))
    end
    return true
end

function CMD.unregister_service(addr)
    g_services[addr] = nil
    return true
end

-- 合并后的快照，给需要自己处理数据的调用方
function CMD.gather()
    return scrape()
end

-- Prometheus 文本格式
function CMD.render()
    return metrics_text.render(scrape())
end

local GM_CMD = {
    metrics = {
        desc = "Dump metrics in Prometheus text format",
        params = {},
        handler = function()
            return true, metrics_text.render(scrape())
        end,
    },
}

skynet.start(function()
    -- 先注册名字再做别的：业务服务一起来就会找 .metrics，晚一步它们就得走重试
    cmd_api.dispatch(CMD)
    skynet.register(".metrics")

    -- 指标端口和 GM 一样默认只听回环：抓取端点不鉴权，暴露出去等于把内部拓扑公开
    local host = config.get("metrics_http_host") or "127.0.0.1"
    local port = config.get_number("metrics_http_port") or 9091
    local server = http_server.new("metrics")
    server:start({ host = host, port = port, agent_count = 1 })
    server:register_router("skyext.metrics_router")
    log.info("metrics HTTP server started", "host", host, "port", port)

    gm_api.register(GM_CMD)
    log.info("metrics service started")
end)

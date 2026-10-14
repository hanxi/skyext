local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/metrics.lua")

local DBMGR_A = 0x01000002
local DBMGR_B = 0x01000003
local GATE = 0x01000004

-- launcher 描述的真实样子 -> 期望归一出来的服务名
local DESCS = {
    ["snlua gm"] = "gm",
    ["snlua service_cell http_watchdog_gm"] = "http_watchdog_gm",
    ["snlua service_cell http_agent_gm_2"] = "http_agent_gm",
    ["snlua mongo_conn:center:1 center 1"] = "mongo_conn",
}

local function addr_string(addr)
    return string.format(":%08x", addr)
end

local function harness(opts)
    opts = opts or {}
    local h = {
        -- addr -> collect_metrics 的回包，nil 表示这次没回（超时或挂了）
        responses = {},
        logs = {},
        conf = opts.conf or {},
        clock = 0,
        launcher = opts.launcher or {
            [addr_string(DBMGR_A)] = "snlua dbmgr db1",
            [addr_string(DBMGR_B)] = "snlua dbmgr db2",
            [addr_string(GATE)] = "snlua gate",
        },
    }
    local noop = function() end

    local function record_log(level)
        return function(...)
            h.logs[#h.logs + 1] = { level = level, text = table.concat({ ... }, " ") }
        end
    end

    local imports = {
        skynet = {
            start = function(fn)
                h.boot = fn
            end,
            register = function(name)
                h.registered_name = name
            end,
            address = addr_string,
            hpc = function()
                h.clock = h.clock + 2000000 -- 每次读表前进 2ms
                return h.clock
            end,
            call = function(addr, _, cmd)
                t.expect(addr).to.equal(".launcher")
                t.expect(cmd).to.equal("LIST")
                if h.launcher_error then
                    error(h.launcher_error, 0)
                end
                return h.launcher
            end,
            request = function()
                local entries = {}
                return {
                    add = function(_, entry)
                        entries[#entries + 1] = entry
                    end,
                    select = function(_, timeout)
                        h.select_timeout = timeout
                        local i = 0
                        return function()
                            while true do
                                i = i + 1
                                local entry = entries[i]
                                if not entry then
                                    return nil
                                end
                                local payload = h.responses[entry[1]]
                                -- 没回的服务在真实 select 里就是不产出，这里跳过
                                if payload ~= nil then
                                    return entry, { payload }
                                end
                            end
                        end
                    end,
                }
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.CMD = CMD
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                return h.conf[key]
            end,
            get_number = function(key)
                return h.conf[key]
            end,
        },
        ["skyext.log"] = {
            info = record_log("info"),
            warn = record_log("warn"),
            error = record_log("error"),
        },
        ["skyext.http_server"] = {
            new = function(name)
                h.http_name = name
                return {
                    start = function(_, conf)
                        h.http_conf = conf
                    end,
                    register_router = function(_, router)
                        h.http_router = router
                    end,
                }
            end,
        },
        ["skyext.gm_api"] = {
            register = function(GM_CMD)
                h.GM_CMD = GM_CMD
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()
    h.noop = noop
    return h
end

local function snapshot_of(name, kind, labels, value)
    return { { name = name, help = name, kind = kind, samples = { { labels = labels, value = value } } } }
end

local function sample_of(snapshot, name, labels)
    for _, metric in ipairs(snapshot) do
        if metric.name == name then
            for _, sample in ipairs(metric.samples) do
                local matched = true
                for key, expected in pairs(labels or {}) do
                    if sample.labels[key] ~= expected then
                        matched = false
                    end
                end
                if matched then
                    return sample
                end
            end
            return nil
        end
    end
end

t.describe("metrics 服务启动", function()
    t.it("先注册名字再起 HTTP：业务服务一上来就会找 .metrics", function()
        local h = harness()
        t.expect(h.registered_name).to.equal(".metrics")
        t.expect(h.http_name).to.equal("metrics")
        t.expect(h.http_router).to.equal("skyext.metrics_router")
    end)

    t.it("抓取端点默认只听回环", function()
        local h = harness()
        t.expect(h.http_conf.host).to.equal("127.0.0.1")
        t.expect(h.http_conf.port).to.equal(9091)
        t.expect(h.http_conf.agent_count).to.equal(1)
    end)

    t.it("监听地址可以配", function()
        local h = harness({ conf = { metrics_http_host = "0.0.0.0", metrics_http_port = 19091 } })
        t.expect(h.http_conf.host).to.equal("0.0.0.0")
        t.expect(h.http_conf.port).to.equal(19091)
    end)

    t.it("注册了只读级别的 GM 指令", function()
        local h = harness()
        t.expect(h.GM_CMD.metrics.level).to.equal("read")
        local ok, text = h.GM_CMD.metrics.handler()
        t.expect(ok).to.be_truthy()
        t.expect(text).to.contain("skyext_metrics_services")
    end)
end)

t.describe("metrics 服务注册", function()
    t.it("重复注册同一个服务只算一个", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.register_service(DBMGR_A)
        t.expect(sample_of(h.CMD.gather(), "skyext_metrics_services").value).to.equal(1)
    end)

    t.it("注销之后不再被抓取", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.unregister_service(DBMGR_A)
        t.expect(sample_of(h.CMD.gather(), "skyext_metrics_services").value).to.equal(0)
    end)

    t.it("一个服务都没注册时也能出快照", function()
        local h = harness()
        local snapshot = h.CMD.gather()
        t.expect(sample_of(snapshot, "skyext_metrics_services").value).to.equal(0)
        t.expect(sample_of(snapshot, "skynet_services").value).to.equal(3)
    end)
end)

t.describe("metrics 抓取合并", function()
    t.it("把各服务的指标加在一起", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.register_service(DBMGR_B)
        h.responses[DBMGR_A] = { metrics = snapshot_of("calls_total", "counter", { op = "find" }, 3) }
        h.responses[DBMGR_B] = { metrics = snapshot_of("calls_total", "counter", { op = "find" }, 4) }

        t.expect(sample_of(h.CMD.gather(), "calls_total", { op = "find" }).value).to.equal(7)
    end)

    t.it("同名服务的运行时数据按服务名归并", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.register_service(DBMGR_B)
        h.CMD.register_service(GATE)
        h.responses[DBMGR_A] = { runtime = { mqlen = 2, cpu = 1.5, message = 10, memory = 1024 } }
        h.responses[DBMGR_B] = { runtime = { mqlen = 7, cpu = 0.5, message = 20, memory = 2048 } }
        h.responses[GATE] = { runtime = { mqlen = 1, cpu = 0.1, message = 5, memory = 512 } }

        local snapshot = h.CMD.gather()
        local dbmgr = { service = "dbmgr" }
        t.expect(sample_of(snapshot, "skynet_service_instances", dbmgr).value).to.equal(2)
        t.expect(sample_of(snapshot, "skynet_service_mqlen", dbmgr).value).to.equal(9)
        -- 总和看不出积压集中在哪，所以单独留一条最大值
        t.expect(sample_of(snapshot, "skynet_service_mqlen_max", dbmgr).value).to.equal(7)
        t.expect(sample_of(snapshot, "skynet_service_memory_bytes", dbmgr).value).to.equal(3072)
        t.expect(sample_of(snapshot, "skynet_service_cpu_seconds_total", dbmgr).value).to.equal(2)
        t.expect(sample_of(snapshot, "skynet_service_messages_total", dbmgr).value).to.equal(30)
        t.expect(sample_of(snapshot, "skynet_service_instances", { service = "gate" }).value).to.equal(1)
    end)

    t.it("带实例编号的服务名归一，不然扩容一次时间序列就跟着涨", function()
        local launcher = {}
        local expected = {}
        local addr = 0x01000100
        for desc, name in pairs(DESCS) do
            launcher[addr_string(addr)] = desc
            expected[addr] = name
            addr = addr + 1
        end

        local h = harness({ launcher = launcher })
        for service_addr, name in pairs(expected) do
            h.CMD.register_service(service_addr)
            h.responses[service_addr] = { runtime = { mqlen = 1 } }
            t.expect(sample_of(h.CMD.gather(), "skynet_service_mqlen", { service = name })).to.exist()
        end
    end)

    t.it("launcher 里查不到的地址归到 unknown", function()
        local h = harness({ launcher = {} })
        h.CMD.register_service(DBMGR_A)
        h.responses[DBMGR_A] = { runtime = { mqlen = 1 } }
        t.expect(sample_of(h.CMD.gather(), "skynet_service_mqlen", { service = "unknown" }).value).to.equal(1)
    end)

    t.it("launcher 查不动时照常抓取，只是没有服务名", function()
        local h = harness()
        h.launcher_error = "launcher busy"
        h.CMD.register_service(DBMGR_A)
        h.responses[DBMGR_A] = { metrics = snapshot_of("calls_total", "counter", {}, 1) }

        local snapshot = h.CMD.gather()
        t.expect(sample_of(snapshot, "calls_total").value).to.equal(1)
        t.expect(sample_of(snapshot, "skynet_services").value).to.equal(0)
        t.expect(h.logs[#h.logs].level).to.equal("warn")
    end)

    t.it("记录本次抓取的耗时", function()
        local h = harness()
        t.expect(sample_of(h.CMD.gather(), "skyext_metrics_scrape_duration_seconds").value).to.be_gt(0)
    end)

    t.it("抓取超时可以配，默认 3 秒", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.gather()
        t.expect(h.select_timeout).to.equal(300)

        local h2 = harness({ conf = { metrics_scrape_timeout = 50 } })
        h2.CMD.register_service(DBMGR_A)
        h2.CMD.gather()
        t.expect(h2.select_timeout).to.equal(50)
    end)

    t.it("同名不同类型的指标记成错误日志", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.register_service(DBMGR_B)
        h.responses[DBMGR_A] = { metrics = snapshot_of("thing", "counter", {}, 1) }
        h.responses[DBMGR_B] = { metrics = snapshot_of("thing", "gauge", {}, 1) }
        h.CMD.gather()

        local last = h.logs[#h.logs]
        t.expect(last.level).to.equal("error")
        t.expect(last.text).to.contain("thing")
    end)
end)

t.describe("metrics 失联服务", function()
    t.it("没回的服务计入失败数", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.register_service(DBMGR_B)
        h.responses[DBMGR_A] = { metrics = {} }

        local snapshot = h.CMD.gather()
        t.expect(sample_of(snapshot, "skyext_metrics_services").value).to.equal(2)
        t.expect(sample_of(snapshot, "skyext_metrics_scrape_failures").value).to.equal(1)
    end)

    t.it("连续失败 3 次就摘掉，不再拖累后面的抓取", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.gather()
        h.CMD.gather()
        t.expect(sample_of(h.CMD.gather(), "skyext_metrics_services").value).to.equal(1)
        -- 第三次抓取时摘掉，第四次就只剩 0 个
        t.expect(sample_of(h.CMD.gather(), "skyext_metrics_services").value).to.equal(0)
    end)

    t.it("中间回过一次就重新计数", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.CMD.gather()
        h.CMD.gather()
        h.responses[DBMGR_A] = { metrics = {} }
        h.CMD.gather()
        h.responses[DBMGR_A] = nil
        h.CMD.gather()
        h.CMD.gather()
        t.expect(sample_of(h.CMD.gather(), "skyext_metrics_services").value).to.equal(1)
    end)
end)

t.describe("metrics 文本导出", function()
    t.it("render 吐出 Prometheus 文本", function()
        local h = harness()
        h.CMD.register_service(DBMGR_A)
        h.responses[DBMGR_A] = { metrics = snapshot_of("calls_total", "counter", { op = "find" }, 3) }

        local text = h.CMD.render()
        t.expect(text).to.contain("# TYPE calls_total counter")
        t.expect(text).to.contain('calls_total{op="find"} 3')
    end)
end)

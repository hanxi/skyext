-- entity_agentmgr 的两段式启动测试。
-- 该服务依赖 mongo/etcd，无法直接拉起真实实例，这里用沙箱加载服务源码并注入桩模块，
-- 用来确定性地验证「CMD.start 才创建 agent / 全部就绪后才发布」的时序约定。
local lfs = require "lfs"
local t = require "skytest"
local fs = require "skyext.util.fs"

local SOURCE = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service", "entity_agentmgr.lua")

local MODULES_DIR = "./nodes/role/modules"

local function new_fake_lfs()
    local tree = {
        [MODULES_DIR] = { mode = "directory", entries = { "bag", "mail", "empty", "notes.txt" } },
        [MODULES_DIR .. "/bag"] = { mode = "directory" },
        [MODULES_DIR .. "/bag/init.lua"] = { mode = "file" },
        [MODULES_DIR .. "/mail"] = { mode = "directory" },
        [MODULES_DIR .. "/mail/request.lua"] = { mode = "file" },
        [MODULES_DIR .. "/empty"] = { mode = "directory" },
        [MODULES_DIR .. "/notes.txt"] = { mode = "file" },
    }
    return {
        attributes = function(path, what)
            local node = tree[path]
            if not node then
                return nil
            end
            if what == "mode" then
                return node.mode
            end
            return { mode = node.mode }
        end,
        dir = function(path)
            local node = assert(tree[path], "no such dir: " .. path)
            local entries = { ".", ".." }
            for _, name in ipairs(node.entries or {}) do
                entries[#entries + 1] = name
            end
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end,
    }
end

-- 加载服务源码并注入桩模块，返回测试句柄
local function new_harness(opts)
    opts = opts or {}

    local h = {
        events = {}, -- 调用顺序
        agents = {}, -- 已创建的 agent 地址
        agent_starts = {}, -- 每个 agent 收到的 start 参数
        registered = {}, -- cluster_discovery.register 的调用
        wakeups = {},
        shutdown_replies = {},
        now = 0,
        activated = {},
    }

    local function record(event, detail)
        h.events[#h.events + 1] = event
        if detail then
            h.events[#h.events] = event .. ":" .. tostring(detail)
        end
    end

    local next_addr = 0x01000100

    local fake_skynet = {
        start = function(f)
            h.boot = f
        end,
        register = function(name)
            h.local_name = name
        end,
        getenv = function(key)
            return (opts.env or { start = "role" })[key]
        end,
        self = function()
            return 0x01000001
        end,
        newservice = function(name, ...)
            record("newservice", name)
            if opts.on_newservice then
                opts.on_newservice(h, name, ...)
            end
            next_addr = next_addr + 1
            h.agents[#h.agents + 1] = next_addr
            return next_addr
        end,
        call = function(addr, _, cmd, arg)
            record("call", cmd)
            if opts.on_call then
                opts.on_call(h, addr, cmd, arg)
            end
            if cmd == "activate" then
                h.activated[#h.activated + 1] = arg
                return table.unpack(h.activate_reply or { true })
            end
            if cmd == "shutdown" then
                -- 每个 agent 依次报告还剩几个实体卸不掉
                local remaining = table.remove(h.shutdown_replies, 1)
                if remaining == "error" then
                    error("agent gone")
                end
                return remaining
            end
            if cmd == "start" then
                h.agent_starts[#h.agent_starts + 1] = { addr = addr, conf = arg }
            end
            return true
        end,
        uniqueservice = function(name)
            record("uniqueservice", name)
            if opts.uniqueservice_error then
                error(opts.uniqueservice_error)
            end
            next_addr = next_addr + 1
            return next_addr
        end,
        wait = function(token)
            record("wait")
            coroutine.yield("wait", token)
        end,
        wakeup = function(token)
            record("wakeup")
            h.wakeups[#h.wakeups + 1] = token
        end,
        -- 停服用：fork 直接内联执行，时间只在 sleep 时前进
        fork = function(f)
            f()
        end,
        now = function()
            return h.now
        end,
        sleep = function(ticks)
            record("sleep")
            h.now = h.now + ticks
        end,
    }

    local noop_log = function() end
    local fake_log = { debug = noop_log, info = noop_log, warn = noop_log, error = noop_log }

    local modules = {
        skynet = fake_skynet,
        lfs = new_fake_lfs(),
        ["skyext.log"] = fake_log,
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.CMD = CMD
            end,
            register = function() end,
        },
        ["skyext.entity.types"] = {
            get = function()
                return opts.type_config or { agent_count = 2, modules_path = "modules", client_enabled = true }
            end,
            preload_ids = function()
                return opts.preload_ids or {}
            end,
            calc_node = function(_, id)
                return (opts.placement or {})[id] or "node-a"
            end,
            calc_agent_index = function()
                return 1
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                assert(key == "cluster_node_name")
                return "node-a"
            end,
        },
        ["skyext.timer"] = {
            repeat_delayed = function(name, sec, fn)
                h.preload_timer = { name = name, sec = sec, fire = fn }
                function h.preload_timer.cancel()
                    h.preload_timer.cancelled = true
                end
                return h.preload_timer
            end,
        },
        ["skyext.cluster_discovery"] = {
            register = function(services)
                record("cluster_register", services[1])
                h.registered[#h.registered + 1] = services
            end,
            unregister = function(services)
                record("cluster_unregister", services[1])
            end,
        },
    }

    local env = setmetatable({
        require = function(name)
            return assert(modules[name], "unexpected require in entity_agentmgr: " .. name)
        end,
    }, { __index = _G })

    local chunk = assert(loadfile(SOURCE, "t", env))
    chunk("role")
    assert(h.boot, "service did not call skynet.start")
    h.boot()
    assert(h.CMD, "service did not dispatch CMD")
    return h
end

local function index_of(events, name)
    for i, event in ipairs(events) do
        if event == name then
            return i
        end
    end
    return nil
end

t.describe("entity_agentmgr 两段式启动", function()
    t.it("skynet.start 阶段不创建任何 agent", function()
        local h = new_harness()
        t.expect(#h.agents).to.equal(0)
        t.expect(#h.registered).to.equal(0)
        t.expect(h.CMD.is_ready()).to.equal(false)
    end)

    t.it("CMD.start 创建全部 agent 并把模块清单与路径交给它们", function()
        local h = new_harness()

        t.expect(h.CMD.start()).to.equal(true)

        t.expect(#h.agents).to.equal(2)
        t.expect(#h.agent_starts).to.equal(2)
        for _, item in ipairs(h.agent_starts) do
            t.expect(item.conf.modules_path).to.equal("modules")
            -- 带上磁盘上有哪些文件，agent 才能对「文件在却 require 不到」直接报错
            t.expect(item.conf.modules).to.equal({
                { name = "bag", init = true, request = false },
                { name = "mail", init = false, request = true },
            })
        end
        t.expect(h.CMD.agents()).to.equal(h.agents)
    end)

    t.it("全部 agent 启动并注册之后才 ready 并发布到集群", function()
        local h = new_harness()
        h.CMD.start()

        t.expect(h.events).to.equal({
            "newservice:entity_agent",
            "call:start",
            "newservice:entity_agent",
            "call:start",
            "uniqueservice:entity_dlq",
            "cluster_register:entity:role",
        })
        t.expect(h.CMD.is_ready()).to.equal(true)
        t.expect(#h.registered).to.equal(1)
    end)

    -- 死信队列只是运维入口，起不来不该让整个实体类型对外不可用
    t.it("entity_dlq 启动失败不影响 ready 与集群发布", function()
        local h = new_harness({ uniqueservice_error = "no such service" })
        h.CMD.start()

        t.expect(h.CMD.is_ready()).to.equal(true)
        t.expect(#h.registered).to.equal(1)
    end)

    t.it("agent 启动失败时错误向上传播且不进入 ready", function()
        local h = new_harness({
            on_call = function(handle, _, cmd)
                if cmd == "start" and #handle.agent_starts == 1 then
                    error("agent boot failed")
                end
            end,
        })

        t.expect(function()
            h.CMD.start()
        end).to
            .throw("agent boot failed")

        t.expect(h.CMD.is_ready()).to.equal(false)
        t.expect(#h.registered).to.equal(0)
        t.expect(index_of(h.events, "cluster_register:entity:role")).to.be_nil()

        -- 失败状态是粘性的：再次 start 仍然报同样的错，不会半启动
        t.expect(function()
            h.CMD.start()
        end).to
            .throw("agent boot failed")
        t.expect(#h.agents).to.equal(2)
    end)

    t.it("重复 start 是安全的：已就绪时直接返回，不再创建 agent", function()
        local h = new_harness()
        h.CMD.start()
        t.expect(h.CMD.start()).to.equal(true)
        t.expect(#h.agents).to.equal(2)
        t.expect(#h.registered).to.equal(1)
    end)

    t.it("并发 start 等待首次启动完成而不是重复创建 agent", function()
        local blocked = true
        local h = new_harness({
            on_newservice = function()
                if blocked then
                    coroutine.yield("block")
                end
            end,
        })

        local first = coroutine.create(function()
            return h.CMD.start()
        end)
        local ok, kind = coroutine.resume(first)
        t.expect(ok).to.equal(true)
        t.expect(kind).to.equal("block")

        -- 第二个调用者应挂起等待，而不是再创建一批 agent
        local second = coroutine.create(function()
            return h.CMD.start()
        end)
        local ok2, kind2 = coroutine.resume(second)
        t.expect(ok2).to.equal(true)
        t.expect(kind2).to.equal("wait")

        blocked = false
        while coroutine.status(first) == "suspended" do
            local resumed, result = coroutine.resume(first)
            t.expect(resumed).to.equal(true)
            if coroutine.status(first) == "dead" then
                t.expect(result).to.equal(true)
            end
        end

        t.expect(#h.wakeups).to.equal(1)
        local ok3, result3 = coroutine.resume(second)
        t.expect(ok3).to.equal(true)
        t.expect(result3).to.equal(true)
        t.expect(#h.agents).to.equal(2)
        t.expect(#h.registered).to.equal(1)
    end)
end)

t.describe("entity_agentmgr 停服", function()
    local function started()
        local h = new_harness()
        h.CMD.start()
        h.events = {}
        return h
    end

    t.it("用本地名字登记自己，停服编排靠它找到本节点的实体类型", function()
        local h = new_harness()
        t.expect(h.local_name).to.equal(".entity_agentmgr:role")
    end)

    t.it("先从服务发现摘掉自己，再让每个 agent 卸载实体", function()
        local h = started()
        h.shutdown_replies = { 0, 0 }
        t.expect(h.CMD.shutdown(10)).to.equal(0)
        -- fork 在桩里内联执行，最后一个 agent 回来时会多出一次（没人等的）wakeup
        t.expect(h.events).to.equal({ "cluster_unregister:entity:role", "call:shutdown", "call:shutdown", "wakeup" })
        t.expect(h.CMD.is_ready()).to.equal(false)
    end)

    t.it("有实体卸不掉时每秒重试一轮，卸干净就返回", function()
        local h = started()
        h.shutdown_replies = { 1, 0, 0, 0 }
        t.expect(h.CMD.shutdown(10)).to.equal(0)
        t.expect(index_of(h.events, "sleep")).to.equal(5)
        t.expect(#h.shutdown_replies).to.equal(0)
    end)

    t.it("超时后报告剩余实体数，agent 调用出错按至少剩一个算", function()
        local h = started()
        h.shutdown_replies = { 2, "error", 2, "error" }
        t.expect(h.CMD.shutdown(1)).to.equal(3)
    end)
end)

t.describe("entity_agentmgr 预加载", function()
    local function preload_harness()
        return new_harness({
            type_config = { agent_count = 1, preload = { "game1", "game2" } },
            preload_ids = { 11, 12 },
            placement = { [11] = "node-a", [12] = "node-b" },
        })
    end

    t.it("就绪后只加载 HRW 落在本节点的那几个 ID，并定期再对一遍", function()
        local h = preload_harness()
        h.CMD.start()
        t.expect(h.activated).to.equal({ 11 })
        t.expect(h.preload_timer.name).to.equal("entity_preload:role")
        h.preload_timer.fire()
        t.expect(h.activated).to.equal({ 11, 11 })
    end)

    t.it("没配 preload 的类型不起定时器", function()
        local h = new_harness()
        h.CMD.start()
        t.expect(h.preload_timer).to.be_nil()
        t.expect(h.activated).to.equal({})
    end)

    t.it("停服后不再预加载", function()
        local h = preload_harness()
        h.CMD.start()
        h.shutdown_replies = { 0 }
        h.CMD.shutdown(1)
        t.expect(h.preload_timer.cancelled).to.equal(true)
        h.preload_timer.fire()
        t.expect(h.activated).to.equal({ 11 })
    end)
end)

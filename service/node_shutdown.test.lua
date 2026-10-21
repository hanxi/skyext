local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/node_shutdown.lua")

-- opts.types       entity_types 配置；false 表示没配（types.all 抛错）
-- opts.local_names 本节点起了的 entity_agentmgr：名字 -> 地址
local function harness(opts)
    opts = opts or {}
    local h = { calls = {}, logs = {}, remaining = {}, fail = {} }

    local function record(addr, cmd)
        h.calls[#h.calls + 1] = addr .. " " .. cmd
    end

    local fake_skynet = {
        start = function(f)
            h.boot = f
        end,
        call = function(addr, _, cmd)
            record(addr, cmd)
            if h.fail[addr] then
                error(h.fail[addr])
            end
            if cmd == "shutdown" then
                return h.remaining[addr] or 0
            end
            return true
        end,
        localname = function(name)
            return (opts.local_names or {})[name]
        end,
        -- fork 默认内联执行；defer_fork 时只排队，模拟停服还在进行中
        fork = function(f, ...)
            if h.defer_fork then
                h.deferred = h.deferred or {}
                h.deferred[#h.deferred + 1] = f
                return
            end
            f(...)
        end,
        wait = function() end,
        wakeup = function() end,
        abort = function()
            h.aborted = true
        end,
    }
    local function log_fn(level)
        return function(msg)
            h.logs[#h.logs + 1] = level .. ":" .. msg
        end
    end
    local types = opts.types
    if types == nil then
        types = { role = {}, guild = {} }
    end
    local imports = {
        skynet = fake_skynet,
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                h.CMD = cmd
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.GM = cmds
            end,
        },
        ["skyext.cluster_discovery"] = {
            shutdown = function()
                record("discovery", "shutdown")
                return true
            end,
        },
        ["skyext.entity.types"] = {
            all = function()
                if types == false then
                    error("entity_types is not configured")
                end
                return types
            end,
        },
        ["skyext.log"] = { info = log_fn("info"), warn = log_fn("warn"), error = log_fn("error") },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()
    return h
end

local function logged(h, entry)
    for _, line in ipairs(h.logs) do
        if line == entry then
            return true
        end
    end
    return false
end

t.describe("node_shutdown", function()
    t.it("runs the phases in order and exits only after every entity is unloaded", function()
        local h = harness({ local_names = { [".entity_agentmgr:role"] = ":mgr" } })
        h.CMD.add_hook("stop_accepting", ":gate_owner", "stop_accepting")
        h.CMD.add_hook("release", ":snowflake", "shutdown")
        t.expect(table.pack(h.CMD.shutdown(30))).to.equal({ true, "shutdown started", n = 2 })
        t.expect(h.calls).to.equal({
            ":gate_owner stop_accepting",
            ":mgr shutdown",
            ":snowflake shutdown",
            "discovery shutdown",
            ".logger close",
        })
        t.expect(h.aborted).to.equal(true)
    end)

    t.it("only unloads the entity types that run on this node", function()
        -- guild 配置了但本节点没起它的 agentmgr
        local h = harness({ local_names = { [".entity_agentmgr:role"] = ":mgr" } })
        h.CMD.shutdown()
        local shutdowns = 0
        for _, call in ipairs(h.calls) do
            if call:find(" shutdown$") and call ~= "discovery shutdown" then
                shutdowns = shutdowns + 1
            end
        end
        t.expect(shutdowns).to.equal(1)
    end)

    t.it("keeps the process alive when entities remain, and can be retried", function()
        local h = harness({ local_names = { [".entity_agentmgr:role"] = ":mgr" } })
        h.CMD.add_hook("release", ":snowflake", "shutdown")
        h.remaining[":mgr"] = 3
        h.CMD.shutdown()
        t.expect(h.aborted).to.be_nil()
        t.expect(h.calls).to.equal({ ":mgr shutdown" })
        t.expect(logged(h, "error:node shutdown incomplete, process kept alive")).to.equal(true)

        h.remaining[":mgr"] = 0
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(h.aborted).to.equal(true)
    end)

    t.it("counts an unreachable entity manager as not unloaded", function()
        local h = harness({ local_names = { [".entity_agentmgr:role"] = ":mgr" } })
        h.fail[":mgr"] = "service gone"
        h.CMD.shutdown()
        t.expect(h.aborted).to.be_nil()
    end)

    t.it("rejects a second shutdown while one is running", function()
        local h = harness()
        h.defer_fork = true
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(table.pack(h.CMD.shutdown())).to.equal({ false, "already shutting down", n = 2 })
    end)

    t.it("carries on when a hook fails", function()
        local h = harness()
        h.CMD.add_hook("stop_accepting", ":gate_owner", "stop_accepting")
        h.fail[":gate_owner"] = "gate already closed"
        h.CMD.shutdown()
        t.expect(h.aborted).to.equal(true)
        t.expect(logged(h, "warn:shutdown hook failed")).to.equal(true)
    end)

    t.it("shuts down a node without any entity types", function()
        local h = harness({ types = false })
        h.CMD.shutdown()
        t.expect(h.calls).to.equal({ "discovery shutdown", ".logger close" })
        t.expect(h.aborted).to.equal(true)
    end)

    t.it("records a hook once and rejects an unknown phase", function()
        local h = harness()
        h.CMD.add_hook("release", ":a", "shutdown")
        h.CMD.add_hook("release", ":a", "shutdown")
        h.CMD.shutdown()
        t.expect(h.calls[1]).to.equal(":a shutdown")
        t.expect(h.calls[2]).to.equal("discovery shutdown")
        t.expect(function()
            h.CMD.add_hook("later", ":a", "shutdown")
        end).to
            .throw("unknown shutdown phase")
    end)

    t.it("exposes shutdown as a GM command", function()
        local h = harness()
        h.defer_fork = true
        t.expect(table.pack(h.GM.shutdown.handler({ timeout = "5" }))).to.equal({ true, "shutdown started", n = 2 })
    end)
end)

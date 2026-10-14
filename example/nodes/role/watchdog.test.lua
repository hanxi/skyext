local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/nodes/role/watchdog.lua")

local GATE = ":gate"
local LOGIN = ":login"
local FORWARD = ":entity_agent"

-- watchdog 是个服务 chunk：加载时会 skynet.start 注册启动函数，
-- 这里把启动函数截下来立刻执行，就能拿到内部的 CMD/SOCKET 表。
local function harness()
    local h = {
        calls = {},
        sends = {},
        logs = {},
        fail_cmd = {}, -- cmd -> 错误信息，让 skynet.call 抛错
        fail_send = false,
    }

    local function record(level, msg, ...)
        h.logs[#h.logs + 1] = { level = level, msg = msg, args = { ... } }
    end

    local fake_skynet = setmetatable({
        self = function()
            return ":watchdog"
        end,
        newservice = function(name)
            return ":" .. name
        end,
        call = function(addr, _, cmd, ...)
            h.calls[#h.calls + 1] = { addr = addr, cmd = cmd, args = { ... } }
            local fail = h.fail_cmd[cmd]
            if fail then
                error(fail)
            end
            return true
        end,
        send = function(addr, _, cmd, ...)
            if h.fail_send then
                error("send to a dead service")
            end
            h.sends[#h.sends + 1] = { addr = addr, cmd = cmd, args = { ... } }
        end,
        start = function(f)
            h.start = f
        end,
    }, { __index = skynet })

    local modules = {
        skynet = fake_skynet,
        ["skyext.cmd_api"] = {
            dispatch_socket = function(cmd, socket)
                h.CMD = cmd
                h.SOCKET = socket
            end,
            dispatch = function(cmd)
                h.CMD = cmd
            end,
        },
        ["skyext.log"] = {
            debug = function(...)
                record("debug", ...)
            end,
            info = function(...)
                record("info", ...)
            end,
            warn = function(...)
                record("warn", ...)
            end,
            error = function(...)
                record("error", ...)
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })

    local chunk = assert(loadfile(source, "t", env))
    chunk()
    assert(h.start, "watchdog did not register a start function")
    h.start()
    assert(h.CMD and h.SOCKET, "watchdog did not dispatch its command tables")
    return h
end

local function logged(h, msg)
    for _, entry in ipairs(h.logs) do
        if entry.msg == msg then
            return true
        end
    end
    return false
end

-- 一个已经完成登录转发的客户端：open -> forward
local function forwarded_client(h, fd)
    h.SOCKET.open(fd, "127.0.0.1:4321")
    h.CMD.forward(fd, FORWARD)
    -- 建连阶段的记录清掉，只关心断开时发生了什么
    h.calls = {}
    h.sends = {}
    h.logs = {}
    return h
end

t.describe("watchdog close_client", function()
    t.it("kicks the gate and notifies the forward service", function()
        local h = forwarded_client(harness(), 7)
        h.SOCKET.close(7)

        t.expect(#h.calls).to.equal(1)
        t.expect(h.calls[1].addr).to.equal(GATE)
        t.expect(h.calls[1].cmd).to.equal("kick")
        t.expect(h.calls[1].args[1]).to.equal(7)

        t.expect(#h.sends).to.equal(1)
        t.expect(h.sends[1].addr).to.equal(FORWARD)
        t.expect(h.sends[1].cmd).to.equal("disconnect")
        t.expect(h.sends[1].args[1]).to.equal(7)
    end)

    t.it("still notifies the forward service when the gate kick fails", function()
        -- gate 那边连接已经没了/gate 挂了都会让 kick 抛错。
        -- 这时 disconnect 必须照发：forward 目标靠它清掉 entity.fd，
        -- 而 fd 还挂着的实体永远不会进卸载定时器，漏一次就是一条实体泄漏。
        local h = forwarded_client(harness(), 7)
        h.fail_cmd.kick = "call to invalid address"
        h.SOCKET.close(7)

        t.expect(#h.sends).to.equal(1)
        t.expect(h.sends[1].cmd).to.equal("disconnect")
        t.expect(h.sends[1].args[1]).to.equal(7)
        t.expect(logged(h, "kick client failed")).to.equal(true)
    end)

    t.it("drops the client even when the kick fails", function()
        local h = forwarded_client(harness(), 7)
        h.fail_cmd.kick = "gate is gone"
        h.SOCKET.close(7)

        -- 再关一次：客户端必须已经从表里摘掉了，只剩一条告警
        h.sends = {}
        h.SOCKET.close(7)
        t.expect(#h.sends).to.equal(0)
        t.expect(logged(h, "close_client client not found")).to.equal(true)
    end)

    t.it("does not raise when the forward service is already gone", function()
        local h = forwarded_client(harness(), 7)
        h.fail_send = true
        h.SOCKET.error(7, "connection reset")

        t.expect(#h.calls).to.equal(1)
        t.expect(h.calls[1].cmd).to.equal("kick")
        t.expect(logged(h, "notify disconnect failed")).to.equal(true)
    end)

    t.it("CMD.close_client notifies the forward service too", function()
        local h = forwarded_client(harness(), 9)
        h.fail_cmd.kick = "gate is gone"
        h.CMD.close_client(9)

        t.expect(#h.sends).to.equal(1)
        t.expect(h.sends[1].cmd).to.equal("disconnect")
        t.expect(h.sends[1].args[1]).to.equal(9)
    end)

    t.it("does nothing for an unknown fd", function()
        local h = harness()
        h.SOCKET.close(42)

        t.expect(#h.calls).to.equal(0)
        t.expect(#h.sends).to.equal(0)
        t.expect(logged(h, "close_client client not found")).to.equal(true)
    end)

    t.it("does not notify anyone when the client was never forwarded", function()
        -- 还没登录成功就断开的连接：没有 forward 目标，也就不需要 disconnect
        local h = harness()
        h.SOCKET.open(5, "127.0.0.1:1")
        h.calls = {}
        h.sends = {}
        h.SOCKET.close(5)

        t.expect(#h.calls).to.equal(0)
        t.expect(#h.sends).to.equal(0)
    end)

    t.it("opens a client through the login service", function()
        local h = harness()
        h.SOCKET.open(3, "127.0.0.1:2")
        t.expect(#h.calls).to.equal(1)
        t.expect(h.calls[1].addr).to.equal(LOGIN)
        t.expect(h.calls[1].cmd).to.equal("open")
        t.expect(h.calls[1].args[1].fd).to.equal(3)
    end)
end)

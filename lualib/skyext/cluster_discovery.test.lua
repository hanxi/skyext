local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/cluster_discovery.lua")

local SERVICE_ADDR = 0x1234

-- 模块把服务地址和服务对象缓存在 upvalue 里，每个用例都得重新加载一份
local function harness()
    local h = { calls = {}, sends = {}, pick = 1 }

    local noop = function() end

    local imports = {
        skynet = setmetatable({
            init = function(fn)
                h.boot = fn
            end,
            uniqueservice = function(name)
                h.unique = name
                return SERVICE_ADDR
            end,
            send = function(addr, proto, cmd, arg)
                h.sends[#h.sends + 1] = { addr = addr, proto = proto, cmd = cmd, arg = arg }
            end,
            call = function(addr, proto, cmd, arg)
                h.calls[#h.calls + 1] = { addr = addr, proto = proto, cmd = cmd, arg = arg }
                return h.nodes_reply[arg] or {}
            end,
        }, { __index = skynet }),
        ["skyext.event_channel_api"] = {
            subscribe = function(addr, channel, fn)
                h.subscribed = { addr = addr, channel = channel }
                h.on_change = fn
            end,
        },
        ["skyext.log"] = setmetatable({}, {
            __index = function()
                return noop
            end,
        }),
    }

    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
        -- 固定选号，否则没法断言 random 到底是从列表里取的还是别处来的
        math = setmetatable({
            random = function(n)
                h.upper = n
                return h.pick
            end,
        }, { __index = math }),
    }, { __index = _G })

    h.nodes_reply = {}

    h.load = function()
        h.M = assert(loadfile(source, "t", env))()
        return h.M
    end
    h.start = function()
        h.load()
        h.boot()
        return h.M
    end
    return h
end

t.describe("cluster_discovery client registration", function()
    t.it("服务还没起来就调用注册接口时直接报错，而不是把消息发给 nil 地址", function()
        local h = harness()
        local M = h.load() -- 故意不跑 skynet.init 回调
        t.expect(function()
            M.register({ "entity:role" })
        end).to
            .throw("cluster_discovery service not initialized")
        t.expect(function()
            M.unregister({ "entity:role" })
        end).to
            .throw("cluster_discovery service not initialized")
        t.expect(#h.sends).to.equal(0)
    end)

    t.it("启动时拿到唯一服务并订阅服务变更频道", function()
        local h = harness()
        h.start()
        t.expect(h.unique).to.equal("cluster_discovery")
        t.expect(h.subscribed).to.equal({ addr = SERVICE_ADDR, channel = "service_change" })
    end)

    t.it("register 把整份服务列表一次性发给发现服务", function()
        local h = harness()
        local M = h.start()
        M.register({ "entity:role", "entity:guild" })
        t.expect(h.sends[1]).to.equal({
            addr = SERVICE_ADDR,
            proto = "lua",
            cmd = "register",
            arg = { "entity:role", "entity:guild" },
        })
    end)

    t.it("unregister 走的是 unregister 命令，不是 register", function()
        local h = harness()
        local M = h.start()
        M.unregister({ "entity:role" })
        t.expect(h.sends[1].cmd).to.equal("unregister")
        t.expect(h.sends[1].arg).to.equal({ "entity:role" })
    end)
end)

t.describe("cluster_discovery client lookup", function()
    t.it("第一次问某个服务时查一次发现服务，之后走缓存", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:role"] = { "rolenode1", "rolenode2" }

        t.expect(M.nodes("entity:role")).to.equal({ "rolenode1", "rolenode2" })
        M.nodes("entity:role")
        M.random("entity:role")
        -- 每次查询都发一次 call 的话，热路径上的路由会把发现服务打爆
        t.expect(#h.calls).to.equal(1)
        t.expect(h.calls[1]).to.equal({
            addr = SERVICE_ADDR,
            proto = "lua",
            cmd = "query_service",
            arg = "entity:role",
        })
    end)

    t.it("不同服务各查各的", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:role"] = { "rolenode1" }
        h.nodes_reply["entity:guild"] = { "guildnode1" }

        t.expect(M.nodes("entity:role")).to.equal({ "rolenode1" })
        t.expect(M.nodes("entity:guild")).to.equal({ "guildnode1" })
        t.expect(#h.calls).to.equal(2)
    end)

    t.it("random 在节点列表范围内取号", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:role"] = { "rolenode1", "rolenode2", "rolenode3" }

        h.pick = 2
        t.expect(M.random("entity:role")).to.equal("rolenode2")
        -- 取号上界必须是节点数，少一个节点就永远轮不到最后那台
        t.expect(h.upper).to.equal(3)
        h.pick = 3
        t.expect(M.random("entity:role")).to.equal("rolenode3")
    end)

    t.it("服务一个节点都没有时 random 返回 nil 而不是报错", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:role"] = {}
        t.expect(M.random("entity:role")).to.be_nil()
    end)
end)

t.describe("cluster_discovery client change subscription", function()
    t.it("收到变更事件后用新列表替换缓存，不再回查发现服务", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:role"] = { "rolenode1" }
        M.nodes("entity:role")

        h.on_change("entity:role", { "rolenode2", "rolenode3" })
        t.expect(M.nodes("entity:role")).to.equal({ "rolenode2", "rolenode3" })
        t.expect(#h.calls).to.equal(1)
    end)

    t.it("节点被摘光时缓存会变成空列表，random 跟着返回 nil", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:role"] = { "rolenode1" }
        M.nodes("entity:role")

        -- 整组节点下线是常态（滚动发布），缓存必须跟着空掉而不是留着死节点
        h.on_change("entity:role", {})
        t.expect(M.nodes("entity:role")).to.equal({})
        t.expect(M.random("entity:role")).to.be_nil()
    end)

    t.it("没人问过的服务收到变更事件时被忽略，不会凭空建出缓存", function()
        local h = harness()
        local M = h.start()
        h.nodes_reply["entity:guild"] = { "guildnode1" }

        h.on_change("entity:guild", { "stale1", "stale2" })
        -- 事件先于首查到达时若直接建缓存，这份没经过发现服务校验的列表会一直被当真
        t.expect(M.nodes("entity:guild")).to.equal({ "guildnode1" })
        t.expect(#h.calls).to.equal(1)
    end)
end)

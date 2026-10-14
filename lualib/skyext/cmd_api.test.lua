local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/cmd_api.lua")

local function harness()
    local h = { joined = 0, rets = {} }
    local imports = {
        skynet = {
            dispatch = function(proto, fn)
                t.expect(proto).to.equal("lua")
                h.dispatcher = fn
            end,
            ret = function(...)
                h.rets[#h.rets + 1] = table.pack(...)
            end,
            pack = function(...)
                return ...
            end,
        },
        ["skyext.metrics_api"] = {
            ensure_registered = function()
                h.joined = h.joined + 1
                -- 注册时机必须在 dispatch 装好之后：.metrics 随时可能来拉
                h.dispatcher_ready = h.dispatcher ~= nil
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.cmd_api = assert(loadfile(source, "t", env))()
    return h
end

t.describe("cmd_api 分发", function()
    t.it("按命令名找到处理函数并把返回值 ret 回去", function()
        local h = harness()
        h.cmd_api.dispatch({
            add = function(a, b)
                return a + b
            end,
        })
        h.dispatcher(nil, nil, "add", 2, 3)
        t.expect(h.rets[1][1]).to.equal(5)
    end)

    t.it("未知命令报错", function()
        local h = harness()
        h.cmd_api.dispatch({})
        t.expect(function()
            h.dispatcher(nil, nil, "nope")
        end).to
            .throw("Unknown command: nope")
    end)

    t.it("dispatch 之后 register 的命令同样能分发到", function()
        local h = harness()
        h.cmd_api.dispatch({})
        h.cmd_api.register({
            late = function()
                return "ok"
            end,
        })
        h.dispatcher(nil, nil, "late")
        t.expect(h.rets[1][1]).to.equal("ok")
    end)

    t.it("socket 子命令不走 ret，其余命令照常", function()
        local h = harness()
        local got
        h.cmd_api.dispatch_socket({
            ping = function()
                return "pong"
            end,
        }, {
            data = function(payload)
                got = payload
            end,
        })

        h.dispatcher(nil, nil, "socket", "data", "hello")
        t.expect(got).to.equal("hello")
        t.expect(#h.rets).to.equal(0)

        h.dispatcher(nil, nil, "ping")
        t.expect(h.rets[1][1]).to.equal("pong")
    end)
end)

t.describe("cmd_api 挂上指标采集", function()
    t.it("接管消息分发就把服务挂到 .metrics", function()
        local h = harness()
        h.cmd_api.dispatch({})
        t.expect(h.joined).to.equal(1)
        t.expect(h.dispatcher_ready).to.be_truthy()
    end)

    t.it("dispatch_socket 同样挂", function()
        local h = harness()
        h.cmd_api.dispatch_socket({}, {})
        t.expect(h.joined).to.equal(1)
    end)

    t.it("只 register 不分发的不挂：没有 dispatch 就应答不了采集", function()
        local h = harness()
        h.cmd_api.register({})
        t.expect(h.joined).to.equal(0)
    end)
end)

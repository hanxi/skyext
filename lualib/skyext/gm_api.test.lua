local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/gm_api.lua")

local SELF = 1001
local GM_ADDR = 42

local function harness(opts)
    opts = opts or {}
    local h = {
        calls = {},
        warnings = {},
        errors = {},
        localname_lookups = 0,
        gm_addr = opts.gm_addr == nil and GM_ADDR or opts.gm_addr or nil,
    }

    local fake_skynet = {}
    function fake_skynet.localname(name)
        h.localname_lookups = h.localname_lookups + 1
        h.localname_arg = name
        return h.gm_addr
    end
    function fake_skynet.self()
        return SELF
    end
    function fake_skynet.call(addr, proto, cmd, ...)
        h.calls[#h.calls + 1] = { addr = addr, proto = proto, cmd = cmd, args = table.pack(...) }
        if h.call_error then
            error(h.call_error, 0)
        end
        if cmd == "register_commands" then
            return h.register_result or { success_count = 1 }
        end
        return h.call_result
    end

    local fake_cmd_api = {}
    function fake_cmd_api.register(CMD)
        h.registered = CMD
        h.register_count = (h.register_count or 0) + 1
    end

    local imports = {
        skynet = fake_skynet,
        ["skyext.cmd_api"] = fake_cmd_api,
        ["skyext.log"] = {
            info = function() end,
            warn = function(msg)
                h.warnings[#h.warnings + 1] = msg
            end,
            error = function(msg)
                h.errors[#h.errors + 1] = msg
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.gm_api = assert(loadfile(source, "t", env))()
    return h
end

local function one_cmd(extra)
    local def = { desc = "重载资源", handler = function() end }
    for k, v in pairs(extra or {}) do
        def[k] = v
    end
    return { reload_res = def }
end

t.describe("gm_api 注册", function()
    t.it("把 handler 挂成 GM_<大写指令名>，并按原样上报描述和参数", function()
        local h = harness()
        local handler = function() end
        local params = { filepaths = "文件路径列表" }
        t.expect(h.gm_api.register({ reload_res = { desc = "重载资源", handler = handler, params = params } })).to
            .equal(true)

        t.expect(h.localname_arg).to.equal(".gm")
        local call = h.calls[1]
        t.expect(call.addr).to.equal(GM_ADDR)
        t.expect(call.cmd).to.equal("register_commands")
        -- 第一个参数是自己的服务地址：GM 服务靠它把指令路由回来，也靠它批量注销
        t.expect(call.args[1]).to.equal(SELF)
        t.expect(call.args[2]).to.have_length(1)
        t.expect(call.args[2][1].cmd_name).to.equal("reload_res")
        t.expect(call.args[2][1].handler_name).to.equal("GM_RELOAD_RES")
        t.expect(call.args[2][1].desc).to.equal("重载资源")
        t.expect(call.args[2][1].params).to.equal(params)
        -- 上报的 handler_name 必须和挂进 cmd_api 的键一致，否则 GM 服务按名字找不到处理函数
        t.expect(h.registered.GM_RELOAD_RES).to.equal(handler)
    end)

    t.it("省略 params 时上报空表而不是 nil", function()
        local h = harness()
        h.gm_api.register(one_cmd())
        t.expect(h.calls[1].args[2][1].params).to.equal({})
    end)

    t.it("缺 desc 的指令直接抛错，不会半注册", function()
        local h = harness()
        t.expect(function()
            h.gm_api.register({ reload_res = { handler = function() end } })
        end).to
            .throw("must have a desc")
        -- 校验在任何上报之前完成：不能让一半指令进了 GM 服务另一半没进
        t.expect(h.calls).to.have_length(0)
        t.expect(h.registered).to.be_nil()
    end)

    t.it("缺 handler 的指令直接抛错", function()
        local h = harness()
        t.expect(function()
            h.gm_api.register({ reload_res = { desc = "重载资源" } })
        end).to
            .throw("must have a handler")
        t.expect(h.calls).to.have_length(0)
    end)

    t.it("GM 服务还没起来时跳过注册，也不把指令挂到 cmd_api 上", function()
        local h = harness({ gm_addr = false })
        t.expect(h.gm_api.register(one_cmd())).to.equal(false)
        t.expect(h.calls).to.have_length(0)
        -- 关键：没上报成功就不能挂 cmd_api，否则本地有处理函数但 GM 永远不会调过来
        t.expect(h.registered).to.be_nil()
    end)

    t.it("上报调用失败时返回 false 并记 error，不挂 cmd_api", function()
        local h = harness()
        h.call_error = "gm service down"
        t.expect(h.gm_api.register(one_cmd())).to.equal(false)
        t.expect(h.errors).to.have_length(1)
        t.expect(h.registered).to.be_nil()
    end)

    t.it("部分指令上报失败时仍然算注册成功，只记一条 warn", function()
        local h = harness()
        h.register_result = { success_count = 1, failed_commands = { "reload_res" } }
        -- 成功的那部分必须可用，不能因为有指令重名就整批回滚
        t.expect(h.gm_api.register(one_cmd())).to.equal(true)
        t.expect(h.warnings).to.have_length(1)
        t.expect(h.registered.GM_RELOAD_RES).to.exist()
    end)

    t.it("GM 服务地址只解析一次，后续注册复用缓存", function()
        local h = harness()
        h.gm_api.register(one_cmd())
        h.gm_api.register({ kick = { desc = "踢人", handler = function() end } })
        t.expect(h.localname_lookups).to.equal(1)
        t.expect(h.calls).to.have_length(2)
    end)
end)

t.describe("gm_api 注销", function()
    t.it("没有解析过 GM 服务地址时不去调用，直接返回 false", function()
        local h = harness()
        -- unregister 读的是注册时缓存下来的地址，自己不做查找：
        -- 一个从没注册过指令的服务也没什么可注销的
        t.expect(h.gm_api.unregister()).to.equal(false)
        t.expect(h.localname_lookups).to.equal(0)
        t.expect(h.calls).to.have_length(0)
        t.expect(h.warnings).to.have_length(1)
    end)

    t.it("注册过之后按服务地址批量注销", function()
        local h = harness()
        h.gm_api.register(one_cmd())
        t.expect(h.gm_api.unregister()).to.equal(true)
        local call = h.calls[2]
        t.expect(call.cmd).to.equal("unregister_service")
        t.expect(call.args[1]).to.equal(SELF)
    end)

    t.it("注销调用抛错时返回 false 而不是把异常抛给调用方", function()
        local h = harness()
        h.gm_api.register(one_cmd())
        h.call_error = "gm service down"
        t.expect(h.gm_api.unregister()).to.equal(false)
        t.expect(h.errors).to.have_length(1)
    end)
end)

t.describe("gm_api 进程内执行", function()
    t.it("GM 服务缺失时返回错误码而不是抛异常", function()
        local h = harness({ gm_addr = false })
        local result = h.gm_api.execute_command("reload_res", {})
        t.expect(result.code).to.equal(1)
        t.expect(result.error).to.contain("GM service not found")
    end)

    t.it("凭证位传 nil：进程内调用不走 token 鉴权", function()
        local h = harness()
        h.call_result = { code = 0 }
        local params = { filepaths = { "res/a.lua" } }
        local targets = { ".res" }
        h.gm_api.execute_command("reload_res", params, targets)
        local call = h.calls[1]
        t.expect(call.cmd).to.equal("execute_command")
        t.expect(call.args.n).to.equal(4)
        t.expect(call.args[1]).to.be_nil()
        t.expect(call.args[2]).to.equal("reload_res")
        t.expect(call.args[3]).to.equal(params)
        t.expect(call.args[4]).to.equal(targets)
    end)

    t.it("调用失败时把原因包进返回值，调用方不需要 pcall", function()
        local h = harness()
        h.call_error = "timeout"
        local result = h.gm_api.execute_command("reload_res", {})
        t.expect(result.code).to.equal(1)
        t.expect(result.error).to.contain("timeout")
        t.expect(h.errors).to.have_length(1)
    end)

    t.it("原样返回 GM 服务的结果，不做二次包装", function()
        local h = harness()
        h.call_result = { code = 0, results = { { success = true } } }
        t.expect(h.gm_api.execute_command("reload_res", {})).to.equal(h.call_result)
    end)
end)

local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/profiler.lua")

local function frame(src, name, line)
    return { short_src = src, name = name, currentline = line }
end

-- debug 库整个换成替身：一来采样栈可以写死，断言才说得清；
-- 二来 profiler 结束时的 debug.sethook() 会把当前进程里的钩子一并摘掉，
-- 真调下去会顺手卸载 skytest 自己的覆盖率钩子。
local function harness(opts)
    opts = opts or {}
    local h = {
        forked = {},
        errors = {},
        sample_times = opts.sample_times or 0,
        frames = opts.frames or {},
    }

    local fake_debug = {
        sethook = function(fn, mask, count)
            if fn == nil then
                h.hook = nil
                h.hook_cleared = true
                return
            end
            h.hook = fn
            h.hook_mask = mask
            h.hook_count = count
        end,
        -- 采样钩子从 level 2 往外走，所以 level 2 对应 frames[1]
        getinfo = function(level)
            return h.frames[level - 1]
        end,
    }

    local imports = {
        skynet = {
            init = function(fn)
                fn()
            end,
            fork = function(fn)
                h.forked[#h.forked + 1] = fn
            end,
            sleep = function(ticks)
                h.slept = ticks
                if opts.sleep_error then
                    error(opts.sleep_error, 0)
                end
                for i = 1, h.sample_times do
                    if h.before_sample then
                        h.before_sample(i)
                    end
                    h.hook("count")
                end
            end,
        },
        ["skyext.log"] = {
            info = function() end,
            warn = function() end,
            error = function(msg)
                h.errors[#h.errors + 1] = msg
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.GM = cmds
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
        debug = fake_debug,
    }, { __index = _G })
    h.module = assert(loadfile(source, "t", env))()

    -- 采样跑在 skynet.fork 里，攒着不跑才能观察到 sampling 中间态
    function h.run_forks()
        local list = h.forked
        h.forked = {}
        for _, fn in ipairs(list) do
            fn()
        end
    end
    return h
end

t.describe("profiler 采样", function()
    t.it("把每层栈帧拼成 源文件:函数名:行号，整条栈用分号连起来计数", function()
        local h = harness({ sample_times = 2, frames = { frame("a.lua", "foo", 10), frame("b.lua", "bar", 20) } })
        h.module.start("svc", 1)
        h.run_forks()
        t.expect(h.module.result(1)).to.equal("a.lua:foo:10;b.lua:bar:20 2")
        t.expect(h.module.status(1).sample_count).to.equal(2)
    end)

    t.it("不同的栈各自计数，输出按字典序排好", function()
        -- 顺序不稳定的话，两次采样的 diff 完全没法看
        local h = harness({ sample_times = 3, frames = { frame("b.lua", "beta", 2) } })
        h.before_sample = function(i)
            if i == 3 then
                h.frames = { frame("a.lua", "alpha", 1) }
            end
        end
        h.module.start("svc", 1)
        h.run_forks()
        t.expect(h.module.result(1)).to.equal("a.lua:alpha:1 1\nb.lua:beta:2 2")
    end)

    t.it("取不到函数名和行号时用 <anonymous> 和 0 兜底，不让整条栈丢掉", function()
        local h = harness({ sample_times = 1, frames = { {} } })
        h.module.start("svc", 1)
        h.run_forks()
        t.expect(h.module.result(1)).to.equal("?:<anonymous>:0 1")
    end)

    t.it("采到空栈时不计入样本数", function()
        local h = harness({ sample_times = 4, frames = {} })
        h.module.start("svc", 1)
        h.run_forks()
        t.expect(h.module.status(1).sample_count).to.equal(0)
        t.expect(h.module.status(1).status).to.equal("completed")
        t.expect(h.module.result(1)).to.equal("")
    end)

    t.it("采样时长缺省为 10 秒", function()
        local h = harness()
        h.module.start("svc")
        h.run_forks()
        t.expect(h.slept).to.equal(1000)
        t.expect(h.module.status(1).duration).to.equal(10)
    end)

    t.it("freq 参数目前完全不影响采样间隔（已知缺陷）", function()
        -- freq 一路存进会话、也写在 GM 帮助里，但钩子永远是每 10000 条指令触发一次。
        -- 哪天真把 Hz 换算成指令数了，这条就该改。
        local h = harness()
        h.module.start("svc", 1, 500)
        h.run_forks()
        t.expect(h.hook_count).to.equal(10000)
        t.expect(h.hook_mask).to.equal("")
    end)

    t.it("采样结束后把钩子摘掉，不留着拖慢服务", function()
        local h = harness({ sample_times = 1, frames = { frame("a.lua", "foo", 1) } })
        h.module.start("svc", 1)
        h.run_forks()
        t.expect(h.hook_cleared).to.equal(true)
        t.expect(h.hook).to.be_nil()
    end)

    t.it("采样中途抛错也要先摘钩子再把状态记成 error", function()
        -- 回归保护：清钩子那行原来排在 skynet.sleep 后面，sleep 一抛错就跳过去了，
        -- 钩子连同它闭包里的 stacks 表会一直挂在服务上，之后每 10000 条指令白跑一次。
        local h = harness({ sleep_error = "boom" })
        local id = h.module.start("svc", 1)
        h.run_forks()
        t.expect(h.hook).to.be_nil()
        t.expect(h.module.status(id).status).to.equal("error")
        t.expect(h.errors).to.have_length(1)
    end)

    t.it("采样失败不会把异常甩给调用方，result 返回带状态的原因", function()
        local h = harness({ sleep_error = "boom" })
        local id = h.module.start("svc", 1)
        h.run_forks()
        local data, err = h.module.result(id)
        t.expect(data).to.be_nil()
        t.expect(err).to.contain("sampling not completed")
        t.expect(err).to.contain("error")
    end)

    t.it("会话 ID 逐个递增，不会撞号", function()
        local h = harness()
        t.expect(h.module.start("a", 1)).to.equal(1)
        t.expect(h.module.start("b", 1)).to.equal(2)
    end)

    t.it("采样跑在调用方自己的进程里，target 只是记在会话上给人看", function()
        -- 钩子装的是当前 Lua 虚拟机，拿不到别的服务的栈；GM 帮助里的"目标服务名"名不副实
        local h = harness({ sample_times = 1, frames = { frame("a.lua", "foo", 1) } })
        h.module.start("other.service", 1)
        h.run_forks()
        t.expect(h.module.status(1).target).to.equal("other.service")
        t.expect(h.module.result(1)).to.equal("a.lua:foo:1 1")
    end)
end)

t.describe("profiler 会话查询", function()
    t.it("采样还没跑完时状态是 sampling，result 拒绝返回半截数据", function()
        local h = harness({ sample_times = 1, frames = { frame("a.lua", "foo", 1) } })
        local id = h.module.start("svc", 1)
        t.expect(h.module.status(id).status).to.equal("sampling")
        local data, err = h.module.result(id)
        t.expect(data).to.be_nil()
        t.expect(err).to.contain("sampling not completed")
    end)

    t.it("查不存在的会话返回 nil", function()
        local h = harness()
        t.expect(h.module.status(999)).to.be_nil()
    end)

    t.it("取不存在会话的结果返回明确原因", function()
        local h = harness()
        local data, err = h.module.result(999)
        t.expect(data).to.be_nil()
        t.expect(err).to.equal("session not found")
    end)

    t.it("不带会话 ID 时列出全部会话，列表形态不含 duration", function()
        local h = harness()
        h.module.start("a", 1)
        h.module.start("b", 1)
        local list = h.module.status()
        t.expect(list).to.have_length(2)
        table.sort(list, function(x, y)
            return x.id < y.id
        end)
        t.expect(list[1].target).to.equal("a")
        t.expect(list[2].target).to.equal("b")
        t.expect(list[1].duration).to.be_nil()
    end)
end)

t.describe("profiler GM 指令", function()
    t.it("注册 start/status/result 三个指令，都带描述和处理函数", function()
        local h = harness()
        for _, name in ipairs({ "profiler_start", "profiler_status", "profiler_result" }) do
            t.expect(h.GM[name].desc).to.be_type("string")
            t.expect(h.GM[name].handler).to.be_type("function")
        end
    end)

    t.it("GM 传来的字符串参数先转成数字再用", function()
        -- GM 走 HTTP，参数一律是字符串；不转的话 status 回出去的 duration 类型就变了
        local h = harness()
        local ok, data = h.GM.profiler_start.handler({ service = "svc", duration = "3", freq = "50" })
        t.expect(ok).to.equal(true)
        t.expect(data.session_id).to.equal(1)
        h.run_forks()
        t.expect(h.slept).to.equal(300)
        t.expect(h.module.status(1).duration).to.be_type("number")
        t.expect(h.module.status(1).duration).to.equal(3)
    end)

    t.it("profiler_status 不带 session_id 时返回全部会话", function()
        local h = harness()
        h.module.start("a", 1)
        local ok, list = h.GM.profiler_status.handler({})
        t.expect(ok).to.equal(true)
        t.expect(list).to.have_length(1)
    end)

    t.it("profiler_status 带 session_id 时只返回那一条", function()
        local h = harness()
        h.module.start("a", 1)
        h.module.start("b", 1)
        local ok, one = h.GM.profiler_status.handler({ session_id = "2" })
        t.expect(ok).to.equal(true)
        t.expect(one.id).to.equal(2)
        t.expect(one.target).to.equal("b")
    end)

    t.it("profiler_result 取不到结果时返回 false 和原因", function()
        local h = harness()
        local ok, err = h.GM.profiler_result.handler({ session_id = "999" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("session not found")
    end)

    t.it("profiler_result 成功时返回折叠栈文本", function()
        local h = harness({ sample_times = 1, frames = { frame("a.lua", "foo", 7) } })
        h.module.start("svc", 1)
        h.run_forks()
        local ok, data = h.GM.profiler_result.handler({ session_id = "1" })
        t.expect(ok).to.equal(true)
        t.expect(data).to.equal("a.lua:foo:7 1")
    end)
end)

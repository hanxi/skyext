local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local source = fs.join(root, "service/gm_sys.lua")
local FIXTURE = fs.join(root, "service/gm_sys.test/inject_script.lua")

-- 本节点的地址，harbor 号取高 8 位。adjust_address 要把 harbor 或进裸地址里，
-- 用非 0 的 harbor 才能验出这一步有没有被跳过
local SELF = 0x01000008
local HARBOR = 1

local function harness()
    local h = { calls = {}, sends = {}, core_cmds = {}, env = {}, now = 1000 }

    local fake_skynet = setmetatable({
        start = function(f)
            f()
        end,
        self = function()
            return SELF
        end,
        harbor = function(addr)
            return addr >> 24
        end,
        localname = function(name)
            return h.names and h.names[name]
        end,
        now = function()
            return h.now
        end,
        call = function(...)
            h.calls[#h.calls + 1] = table.pack(...)
            if h.call_error then
                error(h.call_error)
            end
            if h.call_result ~= nil then
                return table.unpack(h.call_result, 1, h.call_result.n)
            end
            return "called"
        end,
        send = function(...)
            h.sends[#h.sends + 1] = table.pack(...)
        end,
        newservice = function(name, args)
            h.newservice = { name, args }
            if h.newservice_error then
                error(h.newservice_error)
            end
            return h.newservice_addr
        end,
        getenv = function(name)
            return h.env[name]
        end,
        setenv = function(name, value)
            h.env[name] = value
        end,
        cache = {
            clear = function()
                h.cache_cleared = true
            end,
        },
    }, { __index = skynet })

    local fake_core = {
        command = function(cmd, arg)
            h.core_cmds[#h.core_cmds + 1] = { cmd, arg }
        end,
    }

    local fake_snax = {
        newservice = function(name, args)
            h.snax_new = { name, args }
            if h.snax_error then
                error(h.snax_error)
            end
            return { handle = h.snax_addr }
        end,
    }

    local fake_memory = {
        info = function()
            return h.mem_info or {}
        end,
        total = function()
            return 4096
        end,
        block = function()
            return 2048
        end,
        jestat = function()
            return h.jestat or {}
        end,
        dumpheap = function()
            h.dumped = true
        end,
        profactive = function(flag)
            if flag ~= nil then
                h.profactive_arg = flag
                h.prof = flag
            end
            return h.prof or false
        end,
    }

    local fake_socket = {
        netstat = function()
            return h.netstat or {}
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.core"] = fake_core,
        ["skynet.snax"] = fake_snax,
        ["skynet.memory"] = fake_memory,
        ["skynet.socket"] = fake_socket,
        ["skyext.cmd_api"] = { dispatch = function() end },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.cmds = cmds
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    assert(h.cmds, "gm_sys did not register GM commands")
    return h
end

local function run(h, cmd, params)
    return h.cmds[cmd].handler(params)
end

-- 最后一次 skynet.call 的参数列表
local function last_call(h)
    return h.calls[#h.calls]
end

t.describe("gm_sys 指令注册", function()
    t.it("每条指令都带 desc 和可调用的 handler", function()
        local h = harness()
        local count = 0
        for name, def in pairs(h.cmds) do
            count = count + 1
            t.expect(def.desc).to.be_type("string")
            t.expect(def.handler).to.be_type("function")
            if def.params ~= nil then
                t.expect(def.params).to.be_type("table")
            end
            t.expect(name).to.be_type("string")
        end
        t.expect(count).to.be_gt(20)
    end)
end)

t.describe("gm_sys 服务地址解析", function()
    t.it("裸十六进制地址会被或上本节点的 harbor 号", function()
        local h = harness()
        run(h, "kill", { address = "0a" })
        -- 少了 harbor 这一步就会去杀 0 号 harbor 上的同号服务
        t.expect(last_call(h)[4]).to.equal(0x0a | (HARBOR << 24))
    end)

    t.it("冒号开头的地址原样传给 skynet", function()
        local h = harness()
        run(h, "kill", { address = ":0100000a" })
        t.expect(last_call(h)[4]).to.equal(":0100000a")
    end)

    t.it("点号开头的名字走 localname 查询", function()
        local h = harness()
        h.names = { [".launcher"] = 0x01000003 }
        run(h, "kill", { address = ".launcher" })
        t.expect(last_call(h)[4]).to.equal(0x01000003)
    end)

    -- 地址解析失败必须在动手之前就炸掉，不能把 nil 当地址发出去
    t.it("查不到的服务名直接报错且不发出任何调用", function()
        local h = harness()
        t.expect(function()
            run(h, "kill", { address = ".nosuch" })
        end).to
            .throw("Not a valid name")
        t.expect(h.calls).to.have_length(0)
    end)

    t.it("非十六进制的地址直接报错且不发出任何调用", function()
        local h = harness()
        for _, bad in ipairs({ "", "zz", "hello" }) do
            t.expect(function()
                run(h, "kill", { address = bad })
            end).to
                .throw("Need an address")
        end
        t.expect(h.calls).to.have_length(0)
    end)
end)

t.describe("gm_sys 超时参数", function()
    t.it("不传 timeout 时用默认的 300", function()
        local h = harness()
        run(h, "stat", {})
        t.expect(last_call(h)[4]).to.equal(300)
    end)

    t.it("字符串 timeout 被转成数字", function()
        local h = harness()
        run(h, "mem", { timeout = "50" })
        t.expect(last_call(h)[4]).to.equal(50)
    end)

    -- 0 和负数表示"不限时"，要变成 nil 而不是原样传下去
    t.it("0 和负数的 timeout 变成不限时", function()
        local h = harness()
        run(h, "gc", { timeout = "0" })
        t.expect(last_call(h)[4]).to.be_nil()
        run(h, "gc", { timeout = "-1" })
        t.expect(last_call(h)[4]).to.be_nil()
    end)

    -- 已知缺陷：GM 参数从 HTTP 过来全是字符串，timeout=abc 会在
    -- `tonumber(ti) <= 0` 处抛 "attempt to compare nil with number"，
    -- 返回给运维的是一条 traceback 而不是可读的参数错误。
    t.it("非数字的 timeout 目前会抛原生 Lua 错误（已知缺陷）", function()
        local h = harness()
        t.expect(function()
            run(h, "stat", { timeout = "abc" })
        end).to
            .throw("compare")
    end)
end)

t.describe("gm_sys 服务启动指令", function()
    t.it("启动成功时返回地址到服务名的映射", function()
        local h = harness()
        h.newservice_addr = 0x0100000c
        local ok, data = run(h, "start", { service = "agent", args = "1 2" })
        t.expect(ok).to.equal(true)
        t.expect(h.newservice).to.equal({ "agent", "1 2" })
        t.expect(data).to.equal({ [":0100000c"] = "agent" })
    end)

    -- newservice 抛错和返回 nil 是两回事：前者是启动失败，后者是服务自己退出了
    t.it("newservice 抛错与服务自行退出返回不同的失败原因", function()
        local h = harness()
        h.newservice_error = "boom"
        local ok, err = run(h, "start", { service = "agent" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("Failed to start service")

        local h2 = harness()
        h2.newservice_addr = nil
        local ok2, err2 = run(h2, "start", { service = "agent" })
        t.expect(ok2).to.equal(false)
        t.expect(err2).to.equal("Exit")
    end)

    t.it("log 指令通过 launcher 的 LOGLAUNCH 启动服务", function()
        local h = harness()
        h.call_result = table.pack(0x0100000d)
        local ok, data = run(h, "log", { service = "agent", args = "x" })
        t.expect(ok).to.equal(true)
        t.expect(last_call(h)[3]).to.equal("LOGLAUNCH")
        t.expect(last_call(h)[4]).to.equal("snlua")
        t.expect(last_call(h)[5]).to.equal("agent")
        t.expect(last_call(h)[6]).to.equal("x")
        t.expect(data).to.equal({ [":0100000d"] = "agent" })
    end)

    -- launcher 正常应答但没给地址，说明服务起来又立刻退了，不能报成功
    t.it("LOGLAUNCH 没返回地址时算失败", function()
        local h = harness()
        h.call_result = table.pack(nil)
        local ok, err = run(h, "log", { service = "agent" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("Failed")
    end)

    t.it("LOGLAUNCH 抛错时返回失败而不是把异常抛给调用方", function()
        local h = harness()
        h.call_error = "launcher down"
        local ok, err = run(h, "log", { service = "agent" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("Failed to launch service with log")
    end)

    t.it("snax 启动失败时返回失败而不是抛异常", function()
        local h = harness()
        h.snax_error = "boom"
        local ok, err = run(h, "snax", { service = "pingserver" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("Failed to start snax service")
    end)

    t.it("snax 启动成功时返回 handle 地址", function()
        local h = harness()
        h.snax_addr = 0x0100000e
        local ok, data = run(h, "snax", { service = "pingserver", args = "a" })
        t.expect(ok).to.equal(true)
        t.expect(h.snax_new).to.equal({ "pingserver", "a" })
        t.expect(data).to.equal({ [":0100000e"] = "pingserver" })
    end)
end)

t.describe("gm_sys 注入脚本", function()
    t.it("文件打不开时返回可读错误且不发调用", function()
        local h = harness()
        local ok, err = run(h, "inject", { address = "0a", filename = "/nonexistent/x.lua" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("Can't open")
        t.expect(h.calls).to.have_length(0)
    end)

    t.it("读到的脚本原样送进目标服务的 debug RUN", function()
        local h = harness()
        h.call_result = table.pack(true, "done")
        local ok, output = run(h, "inject", { address = "0a", filename = FIXTURE, args = "argv" })
        t.expect(ok).to.equal(true)
        t.expect(output).to.equal("done")
        local call = last_call(h)
        t.expect(call[2]).to.equal("debug")
        t.expect(call[3]).to.equal("RUN")
        t.expect(call[4]).to.match("injected")
        t.expect(call[5]).to.equal(FIXTURE)
        t.expect(call[6]).to.equal("argv")
    end)

    -- 目标服务返回 false 表示脚本自己执行失败，不能当成注入成功
    t.it("目标服务报告执行失败时整条指令算失败", function()
        local h = harness()
        h.call_result = table.pack(false, "syntax error")
        local ok, err = run(h, "inject", { address = "0a", filename = FIXTURE })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("syntax error")
    end)
end)

t.describe("gm_sys 调试转发指令", function()
    t.it("exit 用 send 而不是 call，避免等一个正在退出的服务回包", function()
        local h = harness()
        local ok, msg = run(h, "exit", { address = "0a" })
        t.expect(ok).to.equal(true)
        t.expect(msg).to.equal("Exit command sent")
        t.expect(h.calls).to.have_length(0)
        t.expect(h.sends[1][1]).to.equal(0x0a | (HARBOR << 24))
        t.expect(h.sends[1][3]).to.equal("EXIT")
    end)

    t.it("dbgcmd 把任意调试命令名转发给目标服务", function()
        local h = harness()
        run(h, "dbgcmd", { address = "0a", cmd = "STAT", args = "x" })
        t.expect(last_call(h)[2]).to.equal("debug")
        t.expect(last_call(h)[3]).to.equal("STAT")
        t.expect(last_call(h)[4]).to.equal("x")
    end)

    t.it("task/uniqtask/info/killtask 各自发出对应的调试命令", function()
        local h = harness()
        run(h, "task", { address = "0a" })
        t.expect(last_call(h)[3]).to.equal("TASK")
        run(h, "uniqtask", { address = "0a" })
        t.expect(last_call(h)[3]).to.equal("UNIQTASK")
        run(h, "info", { address = "0a", args = "detail" })
        t.expect(last_call(h)[3]).to.equal("INFO")
        t.expect(last_call(h)[4]).to.equal("detail")
        run(h, "killtask", { address = "0a", threadname = "th1" })
        t.expect(last_call(h)[3]).to.equal("KILLTASK")
        t.expect(last_call(h)[4]).to.equal("th1")
    end)

    t.it("ping 返回往返耗时", function()
        local h = harness()
        h.now = 100
        local ok, elapsed = run(h, "ping", { address = "0a" })
        t.expect(ok).to.equal(true)
        t.expect(elapsed).to.equal("0")
        t.expect(last_call(h)[3]).to.equal("PING")
    end)
end)

t.describe("gm_sys 日志与信号", function()
    t.it("logon/logoff 把地址格式化成字符串后交给 core", function()
        local h = harness()
        run(h, "logon", { address = "0a" })
        t.expect(h.core_cmds[1]).to.equal({ "LOGON", ":0100000a" })
        run(h, "logoff", { address = "0a" })
        t.expect(h.core_cmds[2]).to.equal({ "LOGOFF", ":0100000a" })
    end)

    t.it("不带 sig 时只发地址，带 sig 时拼成一个参数", function()
        local h = harness()
        run(h, "signal", { address = "0a" })
        t.expect(h.core_cmds[1]).to.equal({ "SIGNAL", ":0100000a" })
        run(h, "signal", { address = "0a", sig = 9 })
        t.expect(h.core_cmds[2]).to.equal({ "SIGNAL", ":0100000a 9" })
    end)

    t.it("clearcache 真的清了代码缓存", function()
        local h = harness()
        local ok, msg = run(h, "clearcache")
        t.expect(ok).to.equal(true)
        t.expect(msg).to.equal("Code cache cleared")
        t.expect(h.cache_cleared).to.equal(true)
    end)
end)

t.describe("gm_sys trace 开关", function()
    t.it("只给 on/off 时当作总开关，转成布尔值发出去", function()
        local h = harness()
        run(h, "trace", { address = "0a", proto = "on" })
        t.expect(last_call(h)[4]).to.equal(true)
        t.expect(last_call(h)[5]).to.be_nil()
        run(h, "trace", { address = "0a", proto = "off" })
        t.expect(last_call(h)[4]).to.equal(false)
    end)

    t.it("给了协议名和 flag 时协议名保持字符串，flag 转布尔", function()
        local h = harness()
        run(h, "trace", { address = "0a", proto = "lua", flag = "on" })
        t.expect(last_call(h)[4]).to.equal("lua")
        t.expect(last_call(h)[5]).to.equal(true)
        run(h, "trace", { address = "0a", proto = "lua", flag = "off" })
        t.expect(last_call(h)[5]).to.equal(false)
    end)

    -- flag 不是 on/true 的任何值都按关处理，不能把 "yes" 当成开
    t.it("无法识别的 flag 一律当作关闭", function()
        local h = harness()
        run(h, "trace", { address = "0a", proto = "lua", flag = "yes" })
        t.expect(last_call(h)[5]).to.equal(false)
    end)

    t.it("只给协议名不给 flag 时两者都原样下发", function()
        local h = harness()
        run(h, "trace", { address = "0a", proto = "lua" })
        t.expect(last_call(h)[4]).to.equal("lua")
        t.expect(last_call(h)[5]).to.be_nil()
    end)
end)

t.describe("gm_sys 内存与网络统计", function()
    t.it("cmem 把服务句柄格式化成可读地址并附上总量", function()
        local h = harness()
        h.mem_info = { [0x0100000a] = 1234 }
        local ok, info = run(h, "cmem")
        t.expect(ok).to.equal(true)
        t.expect(info[":0100000a"]).to.equal(1234)
        t.expect(info.total).to.equal(4096)
        t.expect(info.block).to.equal(2048)
    end)

    t.it("jmem 把字节数换算成 Mb 文本", function()
        local h = harness()
        h.jestat = { allocated = 1048576 }
        local _, info = run(h, "jmem")
        t.expect(info.allocated).to.match("1%.00 Mb")
    end)

    t.it("dumpheap 真的触发了堆转储", function()
        local h = harness()
        local ok = run(h, "dumpheap")
        t.expect(ok).to.equal(true)
        t.expect(h.dumped).to.equal(true)
    end)

    t.it("profactive 不带参数时只读状态，不改开关", function()
        local h = harness()
        h.prof = true
        local ok, msg = run(h, "profactive", {})
        t.expect(ok).to.equal(true)
        t.expect(msg).to.equal("heap profiling is active")
        t.expect(h.profactive_arg).to.be_nil()
    end)

    t.it("profactive 带 on/off 时转成布尔再设置", function()
        local h = harness()
        run(h, "profactive", { flag = "on" })
        t.expect(h.profactive_arg).to.equal(true)
        run(h, "profactive", { flag = "off" })
        t.expect(h.profactive_arg).to.equal(false)
    end)

    t.it("netstat 把字节数和时间戳换算成可读单位", function()
        local h = harness()
        h.now = 1000
        h.netstat = {
            {
                address = 0x0100000a,
                read = 2048,
                write = 2097152,
                wbuffer = 0,
                rtime = 500,
                wtime = nil,
            },
        }
        local ok, stat = run(h, "netstat")
        t.expect(ok).to.equal(true)
        local info = stat[1]
        t.expect(info.address).to.equal(":0100000a")
        t.expect(info.read).to.equal("2.0K")
        t.expect(info.write).to.equal("2.0M")
        -- 0 字节要留空，否则面板上一堆 "0" 淹没真正有流量的连接
        t.expect(info.wbuffer).to.be_nil()
        t.expect(info.rtime).to.equal("5.0s")
        t.expect(info.wtime).to.be_nil()
    end)

    t.it("小于 1K 的字节数原样显示为数字", function()
        local h = harness()
        h.netstat = { { address = 1, read = 512, rtime = nil, wtime = nil } }
        local _, stat = run(h, "netstat")
        t.expect(stat[1].read).to.equal(512)
    end)

    -- 超过 60 秒的空闲要显示成 分:秒，否则运维看到的是一个几千秒的裸数字
    t.it("超过 60 秒的时间换算成分秒格式", function()
        local h = harness()
        h.now = 100000
        h.netstat = { { address = 1, rtime = 0, wtime = nil } }
        local _, stat = run(h, "netstat")
        t.expect(stat[1].rtime).to.match("%d+:")
    end)
end)

t.describe("gm_sys 环境变量", function()
    t.it("setenv 之后 getenv 能读回来", function()
        local h = harness()
        run(h, "setenv", { name = "mode", value = "debug" })
        local ok, data = run(h, "getenv", { name = "mode" })
        t.expect(ok).to.equal(true)
        t.expect(data).to.equal({ mode = "debug" })
    end)

    -- 未设置的变量返回字符串 "nil" 而不是 nil：JSON 里 nil 会让这个 key 整个消失
    t.it("未设置的变量返回字符串 nil 而不是让 key 消失", function()
        local h = harness()
        local _, data = run(h, "getenv", { name = "missing" })
        t.expect(data).to.have_key("missing")
        t.expect(data.missing).to.equal("nil")
    end)
end)

t.describe("gm_sys launcher 转发", function()
    t.it("list/service 分别问 launcher 和 SERVICE", function()
        local h = harness()
        run(h, "list")
        t.expect(last_call(h)[1]).to.equal(".launcher")
        t.expect(last_call(h)[3]).to.equal("LIST")
        run(h, "service")
        t.expect(last_call(h)[1]).to.equal("SERVICE")
        t.expect(last_call(h)[3]).to.equal("LIST")
    end)

    t.it("stat/mem/gc 发往 launcher 的命令名各不相同", function()
        local h = harness()
        run(h, "stat", {})
        t.expect(last_call(h)[3]).to.equal("STAT")
        run(h, "mem", {})
        t.expect(last_call(h)[3]).to.equal("MEM")
        run(h, "gc", {})
        t.expect(last_call(h)[3]).to.equal("GC")
    end)
end)

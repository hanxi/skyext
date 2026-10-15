local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/log/bucket/file.lua")

local LEVEL = { FATAL = 0, ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }

-- 这个 bucket 真的要跟文件系统打交道，所以用临时目录跑真实 io；
-- 只有时钟需要替身，否则按小时/按天切割没法在一次测试里跨过边界。
local function harness(fn)
    local dir = fs.temporary_dir()
    local clock = { now = os.time({ year = 2026, month = 3, day = 5, hour = 10, min = 30 }) }
    local imports = {
        ["skyext.time"] = {
            now = function()
                return clock.now
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    local bucket = assert(loadfile(source, "t", env))()
    local h = {
        dir = dir,
        clock = clock,
        path = fs.join(dir, "app.log"),
        seq = 0,
    }
    function h.new(params)
        params = params or {}
        if params.filename == nil then
            params.filename = h.path
        end
        h.obj = bucket.new(params)
        return h.obj
    end
    -- 每条日志的 msg 都带一个序号，轮转后好认出哪些行去了哪个文件
    function h.put(obj, level, msg)
        h.seq = h.seq + 1
        return obj:put({
            level = level or LEVEL.INFO,
            module = "test",
            line = 1,
            msg = msg or ("line-" .. h.seq),
            events = {},
            timestamp = clock.now,
        })
    end
    function h.read(name)
        return fs.read(fs.join(dir, name or "app.log"))
    end
    function h.names()
        local names = fs.entries(dir)
        table.sort(names)
        return names
    end
    function h.has(name)
        for _, entry in ipairs(h.names()) do
            if entry == name then
                return true
            end
        end
        return false
    end
    local ok, err = pcall(fn, h)
    if h.obj then
        pcall(h.obj.close, h.obj)
    end
    fs.remove_tree(dir)
    if not ok then
        error(err, 0)
    end
end

t.describe("log file bucket", function()
    t.it("不给文件名直接报错，不会悄悄把日志写到别处", function()
        harness(function(h)
            t.expect(function()
                h.new({ filename = false })
            end).to
                .throw("specify a file pattern")
        end)
    end)

    t.it("默认每条都刷盘，进程被杀也不会丢掉已经写过的行", function()
        harness(function(h)
            local obj = h.new()
            t.expect(h.put(obj)).to.equal(true)
            -- 没有 close，直接读文件：内容必须已经在盘上
            t.expect(h.read()).to.contain("line-1")
            t.expect(obj:check_error()).to.equal(false)
        end)
    end)

    t.it("级别超出配置范围的记录被丢弃且不写文件", function()
        harness(function(h)
            local obj = h.new({ level = "WARN-ERROR" })
            t.expect(h.put(obj, LEVEL.INFO)).to.be_nil()
            t.expect(h.put(obj, LEVEL.DEBUG)).to.be_nil()
            t.expect(h.put(obj, LEVEL.FATAL)).to.be_nil()
            t.expect(h.put(obj, LEVEL.WARN, "kept-warn")).to.equal(true)
            t.expect(h.put(obj, LEVEL.ERROR, "kept-error")).to.equal(true)
            local body = h.read()
            t.expect(body).to.contain("kept-warn")
            t.expect(body).to.contain("kept-error")
            t.expect(body).to_not.contain("line-1")
        end)
    end)

    t.it("按行数切割：写满后旧内容进轮转文件，新文件从头开始", function()
        harness(function(h)
            local obj = h.new({ split = "line", maxline = 2 })
            h.put(obj, nil, "a1")
            h.put(obj, nil, "a2")
            h.put(obj, nil, "a3")
            t.expect(h.has("app.log.1")).to.equal(true)
            t.expect(h.read("app.log.1")).to.contain("a1")
            t.expect(h.read("app.log.1")).to.contain("a2")
            -- 第三条触发切割，它自己要落在新文件里，不能被一起搬走
            t.expect(h.read()).to.contain("a3")
            t.expect(h.read()).to_not.contain("a1")
        end)
    end)

    t.it("轮转序号持续递增，不覆盖已经存在的轮转文件", function()
        harness(function(h)
            local obj = h.new({ split = "line", maxline = 1 })
            for i = 1, 5 do
                h.put(obj, nil, "msg" .. i)
            end
            t.expect(h.has("app.log.1")).to.equal(true)
            t.expect(h.has("app.log.2")).to.equal(true)
            -- 每个序号各自保留自己那一批，后一次轮转不能把前一次的结果盖掉
            t.expect(h.read("app.log.1")).to.contain("msg1")
            t.expect(h.read("app.log.1")).to_not.contain("msg2")
            t.expect(h.read("app.log.2")).to.contain("msg2")
            t.expect(h.read("app.log.2")).to_not.contain("msg1")
        end)
    end)

    t.it("启动时已有非空日志会先轮转，不和上一次运行的内容混在一起", function()
        harness(function(h)
            fs.write(h.path, "from-previous-run\n")
            h.new({ split = "line", maxline = 100 })
            t.expect(h.read("app.log.1")).to.contain("from-previous-run")
            t.expect(h.read()).to.equal("")
        end)
    end)

    t.it("没配切割时启动不动已有文件，继续追加", function()
        harness(function(h)
            fs.write(h.path, "from-previous-run\n")
            local obj = h.new()
            h.put(obj, nil, "appended")
            t.expect(h.names()).to.have_length(1)
            local body = h.read()
            t.expect(body).to.contain("from-previous-run")
            t.expect(body).to.contain("appended")
        end)
    end)

    t.it("按大小切割：累计字节超过上限才轮转", function()
        harness(function(h)
            local obj = h.new({ split = "size", maxsize = "120" })
            local chunk = string.rep("x", 60)
            h.put(obj, nil, chunk)
            t.expect(h.names()).to.have_length(1)
            h.put(obj, nil, chunk)
            h.put(obj, nil, chunk)
            t.expect(h.has("app.log.1")).to.equal(true)
        end)
    end)

    t.it("单条就超过上限时不会空转切割", function()
        harness(function(h)
            -- size_mt 要求 self.size > 0 才切，否则一条超大日志会切出一个空文件
            local obj = h.new({ split = "size", maxsize = "10" })
            h.put(obj, nil, string.rep("x", 200))
            t.expect(h.names()).to.have_length(1)
        end)
    end)

    t.it("maxsize 的单位按 KMGTP 解析，不带单位就是字节", function()
        harness(function(h)
            local small = h.new({ split = "size", maxsize = "100", filename = fs.join(h.dir, "bytes.log") })
            t.expect(small.split_mgr.maxsize).to.equal(100)
            small:close()
            local kilo = h.new({ split = "size", maxsize = "2K", filename = fs.join(h.dir, "kilo.log") })
            t.expect(kilo.split_mgr.maxsize).to.equal(2048)
            kilo:close()
            local mega = h.new({ split = "size", maxsize = "1MB", filename = fs.join(h.dir, "mega.log") })
            t.expect(mega.split_mgr.maxsize).to.equal(1048576)
        end)
    end)

    t.it("maxsize 格式非法时启动失败，不退回默认值继续跑", function()
        harness(function(h)
            t.expect(function()
                h.new({ split = "size", maxsize = "100 MB" })
            end).to
                .throw("invalid format")
        end)
    end)

    t.it("按小时切割只在跨过小时边界时轮转", function()
        harness(function(h)
            local obj = h.new({ split = "hour" })
            h.put(obj, nil, "same-hour-1")
            h.clock.now = h.clock.now + 60 * 20
            h.put(obj, nil, "same-hour-2")
            t.expect(h.names()).to.have_length(1)
            h.clock.now = h.clock.now + 60 * 60
            h.put(obj, nil, "next-hour")
            t.expect(h.has("app.log.1")).to.equal(true)
            t.expect(h.read()).to.contain("next-hour")
        end)
    end)

    t.it("按天切割跨过小时不轮转，跨过日期才轮转", function()
        harness(function(h)
            local obj = h.new({ split = "day" })
            h.clock.now = h.clock.now + 3 * 60 * 60
            h.put(obj, nil, "same-day")
            t.expect(h.names()).to.have_length(1)
            h.clock.now = h.clock.now + 24 * 60 * 60
            h.put(obj, nil, "next-day")
            t.expect(h.has("app.log.1")).to.equal(true)
        end)
    end)

    t.it("配了 flush_period 时攒够条数才刷盘", function()
        harness(function(h)
            local obj = h.new({ flush_period = 3 })
            h.put(obj, nil, "buffered-1")
            h.put(obj, nil, "buffered-2")
            -- 还没到阈值，内容应当还在用户态缓冲里
            t.expect(h.read()).to.equal("")
            h.put(obj, nil, "buffered-3")
            t.expect(h.read()).to.contain("buffered-1")
            t.expect(h.read()).to.contain("buffered-3")
        end)
    end)

    t.it("close 会把缓冲里的内容刷出去，之后 put 不写也不抛错", function()
        harness(function(h)
            local obj = h.new({ flush_period = 100 })
            h.put(obj, nil, "pending")
            t.expect(h.read()).to.equal("")
            obj:close()
            t.expect(h.read()).to.contain("pending")
            t.expect(h.put(obj, nil, "after-close")).to.be_nil()
            t.expect(h.read()).to_not.contain("after-close")
            -- 重复 close 不应该炸
            obj:close()
        end)
    end)
end)

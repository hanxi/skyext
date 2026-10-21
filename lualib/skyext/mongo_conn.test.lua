local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local mongo_conn = require "skyext.mongo_conn"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/mongo_conn.lua")

-- 用假连接验证 collection 包装层把参数原样整形后投给 mongo_conn 服务，
-- 不依赖真实 MongoDB。
local function new_fake_coll(coll_name)
    local calls = {}
    local fake_conn = {}
    function fake_conn:call(cmd, ...)
        calls[#calls + 1] = { cmd = cmd, args = { ... } }
        return "ret:" .. cmd
    end
    local fake_db = {}
    function fake_db:_route()
        return fake_conn
    end
    return mongo_conn._new_collection(fake_db, coll_name or "c1"), calls
end

t.describe("mongo_conn collection 包装", function()
    t.it("find 保持 (query, projection) 语义", function()
        local coll, calls = new_fake_coll()
        local ret = coll:find({ a = 1 }, { b = 1 })
        t.expect(ret).to.equal("ret:find")
        t.expect(calls[1].cmd).to.equal("find")
        t.expect(calls[1].args[1]).to.equal("c1")
        t.expect(calls[1].args[2]).to.equal({ a = 1 })
        t.expect(calls[1].args[3]).to.equal({ b = 1 })
    end)

    t.it("find_many 透传 sort/skip/limit/projection", function()
        local coll, calls = new_fake_coll("entity_msg")
        local opts = { sort = { seq = 1 }, skip = 10, limit = 100, projection = { args = 1 } }
        coll:find_many({ status = 0 }, opts)
        t.expect(calls[1].cmd).to.equal("find_many")
        t.expect(calls[1].args[1]).to.equal("entity_msg")
        t.expect(calls[1].args[2]).to.equal({ status = 0 })
        t.expect(calls[1].args[3]).to.equal(opts)
    end)

    t.it("find_many 支持多字段有序 sort 的数组写法", function()
        local coll, calls = new_fake_coll()
        coll:find_many({}, { sort = { { target_id = 1 }, { seq = -1 } } })
        local sort = calls[1].args[3].sort
        t.expect(sort[1]).to.equal({ target_id = 1 })
        t.expect(sort[2]).to.equal({ seq = -1 })
    end)

    t.it("find_and_modify 原样投递 findAndModify 文档", function()
        local coll, calls = new_fake_coll("entity_msg_seq")
        local doc = {
            query = { _id = "role:1" },
            update = { ["$inc"] = { seq = 1 } },
            upsert = true,
            new = true,
        }
        coll:find_and_modify(doc)
        t.expect(calls[1].cmd).to.equal("find_and_modify")
        t.expect(calls[1].args[2]).to.equal(doc)
    end)

    t.it("create_index 两种写法都能透传", function()
        local coll, calls = new_fake_coll()
        coll:create_index({ { a = 1 }, { b = 1 }, name = "a_b" })
        t.expect(calls[1].cmd).to.equal("create_index")
        t.expect(calls[1].args[2].name).to.equal("a_b")
        t.expect(calls[1].args[3]).to.be_nil()

        coll:create_index({ a = 1 }, { unique = true })
        t.expect(calls[2].args[3]).to.equal({ unique = true })
    end)

    t.it("safe_insert/safe_update 用 bson 打包（普通表可直接传）", function()
        local coll, calls = new_fake_coll()
        coll:safe_insert({ msg_id = 1, seq = 2 })
        t.expect(calls[1].cmd).to.equal("raw_safe_insert")
        t.expect(calls[1].args[2]).to.be_type("userdata")

        coll:safe_update({ a = 1 }, { ["$set"] = { b = 2 } }, true, false)
        t.expect(calls[2].cmd).to.equal("raw_safe_update")
        t.expect(calls[2].args[2]).to.be_type("userdata")
    end)

    t.it("safe_delete 把查询和 single 原样交给连接服务", function()
        local coll, calls = new_fake_coll()
        coll:safe_delete({ rid = 7 }, true)
        t.expect(calls[1].cmd).to.equal("safe_delete")
        t.expect(calls[1].args[2]).to.equal({ rid = 7 })
        t.expect(calls[1].args[3]).to.equal(true)
    end)
end)

-- 加载一份全新的 mongo_conn 模块：mongo_config 缓存在模块局部变量里，
-- 而且要在"配置还没注入"的状态下加载，才能复现真实的加载顺序。
local function harness(mongo_config)
    local h = {
        mongo_config = mongo_config, -- nil 表示 config.init() 还没跑
        config_reads = 0,
        services = {},
        calls = {},
        logs = {},
    }

    h.clock = 0

    local function record(level, msg, ...)
        h.logs[#h.logs + 1] = { level = level, msg = msg, args = { ... } }
    end

    local fake_skynet = {
        uniqueservice = function(name, ...)
            h.services[#h.services + 1] = { name = name, args = { ... } }
            return 100 + #h.services
        end,
        call = function(addr, proto, cmd, ...)
            h.calls[#h.calls + 1] = { addr = addr, cmd = cmd, args = { ... } }
            if h.fail then
                error(h.fail, 0)
            end
            if h.multi then
                return table.unpack(h.multi, 1, 3)
            end
            return "ret:" .. tostring(cmd)
        end,
        hpc = function()
            h.clock = h.clock + 2000000 -- 每次读表走 2ms
            return h.clock
        end,
    }

    h.observed = {}
    h.errors = {}
    local fake_metrics = {
        histogram = function()
            return {
                observe = function(_, value, labels)
                    h.observed[#h.observed + 1] = { value = value, op = labels.op }
                end,
            }
        end,
        counter = function()
            return {
                inc = function(_, value, labels)
                    h.errors[#h.errors + 1] = { value = value, op = labels.op }
                end,
            }
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skyext.metrics"] = fake_metrics,
        ["skyext.config"] = {
            get_table = function(key)
                h.config_reads = h.config_reads + 1
                if key == "mongo_config" then
                    return h.mongo_config
                end
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
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.mod = assert(loadfile(source, "t", env))()
    return h
end

-- 日志里出现过某个值（按引用或按字符串比较），用来断言存档没有被整份刷进日志
local function logged(h, value)
    for _, entry in ipairs(h.logs) do
        if entry.msg == value then
            return true
        end
        for _, v in ipairs(entry.args) do
            if v == value then
                return true
            end
        end
    end
    return false
end

t.describe("mongo_conn 惰性读取配置", function()
    t.it("加载期不读 mongo_config", function()
        local h = harness({ game = { connections = 1 } })
        -- 配置是在 skyext 的 skynet.init 回调里注入的，chunk 加载期读到的是 nil。
        -- 一旦在文件顶层读并缓存，这个进程后面所有 mongo 操作都会拿 nil 配置跑。
        t.expect(h.config_reads).to.equal(0)
        t.expect(h.mod.get_collection("game", "role")).to.exist()
        t.expect(h.config_reads).to.be_gt(0)
    end)

    t.it("配置缺失时报错而不是缓存 nil", function()
        local h = harness(nil)
        t.expect(function()
            h.mod.get_collection("game", "role")
        end).to
            .throw("mongo_config is not configured")

        -- 失败的那次不能留下缓存：配置注入后必须能正常建连
        h.mongo_config = { game = { connections = 2 } }
        local coll = h.mod.get_collection("game", "role")
        t.expect(coll).to.exist()
        t.expect(#h.services).to.equal(2)
        t.expect(h.services[1].name).to.equal("mongo_conn:game:1")
        t.expect(h.services[2].name).to.equal("mongo_conn:game:2")
        t.expect(coll:find({ rid = 1 })).to.equal("ret:find")
    end)

    t.it("库没配时报出库名", function()
        local h = harness({ game = { connections = 1 } })
        t.expect(function()
            h.mod.get_collection("global", "server")
        end).to
            .throw("database not configured: global")
    end)

    t.it("同一个库只建一次连接", function()
        local h = harness({ game = { connections = 2 } })
        h.mod.get_collection("game", "role")
        local services = #h.services
        local coll = h.mod.get_collection("game", "mail")
        t.expect(#h.services).to.equal(services)
        t.expect(coll:find_one({ id = 1 })).to.equal("ret:find_one")
        -- 连接池里随机挑一条，地址必须是建过的
        t.expect(h.calls[1].addr).to.be_gt(100)
        t.expect(h.calls[1].addr).to.be_lte(100 + services)
    end)
end)

t.describe("mongo_conn 调用耗时", function()
    t.it("按操作名记录每次调用的耗时", function()
        local h = harness({ game = { connections = 1 } })
        local coll = h.mod.get_collection("game", "role")
        coll:find_one({ id = 1 })
        -- 在调用方这边计时：量到的是业务真正等了多久，包含连接服务自身的排队
        t.expect(#h.observed).to.equal(1)
        t.expect(h.observed[1].op).to.equal("find_one")
        t.expect(h.observed[1].value).to.equal(0.002)
        t.expect(#h.errors).to.equal(0)
    end)

    t.it("调用失败也计时，并把错误原样抛回去", function()
        local h = harness({ game = { connections = 1 } })
        local coll = h.mod.get_collection("game", "role")
        h.fail = "mongo is down"
        t.expect(function()
            coll:find({ id = 1 })
        end).to
            .throw("mongo is down")
        -- 失败的调用往往是最慢的，不计时等于把最该看的那部分数据丢掉
        t.expect(#h.observed).to.equal(1)
        t.expect(h.errors[1].op).to.equal("find")
    end)

    t.it("多返回值原样透传", function()
        local h = harness({ game = { connections = 1 } })
        -- 为了计时要包一层 pcall，返回值不能因此少一个或串位
        h.multi = { true, nil, "err" }
        local coll = h.mod.get_collection("game", "role")
        local a, b, c = coll:find({})
        t.expect(a).to.equal(true)
        t.expect(b).to.be_nil()
        t.expect(c).to.equal("err")
    end)
end)

t.describe("mongo_conn 日志脱敏", function()
    t.it("safe_update 不把存档增量写进日志", function()
        local h = harness({ game = { connections = 1 } })
        local coll = h.mod.get_collection("game", "role")
        local update = { ["$set"] = { password_hash = "hunter2", bag = { items = { 1, 2, 3 } } } }
        coll:safe_update({ rid = 7 }, update, true, false)
        t.expect(logged(h, update)).to.equal(false)
        -- 定位用的信息还是要留着，否则线上没法查问题
        t.expect(logged(h, "safe_update")).to.equal(true)
    end)

    t.it("safe_insert 不把整份存档写进日志", function()
        local h = harness({ game = { connections = 1 } })
        local coll = h.mod.get_collection("game", "role")
        local doc = { rid = 7, name = "alice", secret_field = "s3cr3t" }
        coll:safe_insert(doc)
        t.expect(logged(h, doc)).to.equal(false)
        t.expect(logged(h, "safe_insert")).to.equal(true)
    end)
end)

local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local logger = require "skyext.log.logger"
local log_level = require "skyext.log.log_level"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/log/logger.lua")

-- 静音的 traceback 替身：既避免测试输出噪音，也用于统计是否真的抓了堆栈
local function spy_logger(level)
    local lg = logger.new()
    local calls = 0
    lg:config({
        name = "logger_test",
        level = level or log_level.DEBUG,
        log_src = false,
        traceback = function()
            calls = calls + 1
            return "<traceback>"
        end,
    })
    return lg, function()
        return calls
    end
end

t.describe("logger:config", function()
    t.it("accepts numeric levels from app config", function()
        local lg = logger.new()
        lg:config({ level = 4 })
        t.expect(lg.level).to.equal(log_level.DEBUG)
        lg:config({ level = 0 })
        t.expect(lg.level).to.equal(log_level.FATAL)
    end)

    t.it("accepts level names case-insensitively", function()
        local lg = logger.new()
        lg:config({ level = "INFO" })
        t.expect(lg.level).to.equal(log_level.INFO)
        lg:config({ level = "warn" })
        t.expect(lg.level).to.equal(log_level.WARN)
    end)

    t.it("applies sibling fields together with a numeric level", function()
        local lg = logger.new()
        lg:config({ level = 3, log_src = false, log_table = false })
        t.expect(lg.level).to.equal(log_level.INFO)
        t.expect(lg.log_src).to.equal(false)
        t.expect(lg.log_table).to.equal(false)
    end)

    t.it("rejects out of range numeric levels", function()
        local lg = logger.new()
        t.expect(function()
            lg:config({ level = 99 })
        end).to
            .throw("invalid value: 99")
        -- 配置失败时保持默认级别，而默认级别是 INFO 而不是 DEBUG
        t.expect(lg.level).to.equal(log_level.INFO)
    end)

    t.it("rejects unknown fields", function()
        local lg = logger.new()
        t.expect(function()
            lg:config({ not_a_field = 1 })
        end).to
            .throw("invalid config field")
    end)

    t.it("rejects type mismatches", function()
        local lg = logger.new()
        t.expect(function()
            lg:config({ log_src = "yes" })
        end).to
            .throw("type mismatch for field: log_src")
    end)

    t.it("rejects non table config", function()
        local lg = logger.new()
        t.expect(function()
            lg:config("level=4")
        end).to
            .throw("log config must be a table")
    end)
end)

t.describe("logger:is_enabled", function()
    t.it("reports whether a level passes the filter", function()
        local lg = logger.new()
        lg:config({ level = log_level.WARN })
        t.expect(lg:is_enabled(log_level.FATAL)).to.be_truthy()
        t.expect(lg:is_enabled(log_level.ERROR)).to.be_truthy()
        t.expect(lg:is_enabled(log_level.WARN)).to.be_truthy()
        t.expect(lg:is_enabled(log_level.INFO)).to.be_falsy()
        t.expect(lg:is_enabled(log_level.DEBUG)).to.be_falsy()
    end)
end)

t.describe("logger:error", function()
    t.it("skips the traceback when the level is filtered out", function()
        local lg, calls = spy_logger(log_level.FATAL)
        lg:error("filtered out", "k", "v")
        t.expect(calls()).to.equal(0)
    end)

    t.it("captures the traceback when the level is enabled", function()
        local lg, calls = spy_logger(log_level.ERROR)
        lg:error("visible", "k", "v")
        t.expect(calls()).to.equal(1)
    end)
end)

t.describe("logger error helpers", function()
    t.it("xpcall_msgh logs and returns the original message", function()
        local lg, calls = spy_logger()
        t.expect(lg:xpcall_msgh("boom")).to.equal("boom")
        t.expect(calls()).to.equal(1)
    end)

    t.it("sys_assert passes values through", function()
        local lg = spy_logger()
        local a, b = lg:sys_assert(1, "ok")
        t.expect(a).to.equal(1)
        t.expect(b).to.equal("ok")
    end)

    t.it("sys_assert raises the given message", function()
        local lg = spy_logger()
        t.expect(function()
            lg:sys_assert(false, "assert message")
        end).to
            .throw("assert message")
    end)

    t.it("sys_error raises the given message", function()
        local lg = spy_logger()
        t.expect(function()
            lg:sys_error("error message")
        end).to
            .throw("error message")
    end)

    t.it("does not install global pcall wrappers any more", function()
        t.expect(logger.safe_pcall).to.be_nil()
        t.expect(logger.safe_xpcall).to.be_nil()
    end)
end)

t.describe("logger defaults", function()
    t.it("defaults to INFO so DEBUG cannot reach production by accident", function()
        local lg = logger.new()
        t.expect(lg.level).to.equal(log_level.INFO)
        t.expect(lg:is_enabled(log_level.INFO)).to.equal(true)
        t.expect(lg:is_enabled(log_level.DEBUG)).to.equal(false)
        -- 显式打开 DEBUG 仍然可以
        lg:config({ level = log_level.DEBUG })
        t.expect(lg:is_enabled(log_level.DEBUG)).to.equal(true)
    end)
end)

-- 用一个假的 bucket 把日志记录截下来，验证真正写出去的内容
local function capture_logger(opts)
    opts = opts or {}
    local records = {}
    local fake_bucket = {}
    function fake_bucket:put(record)
        -- logger 复用同一个 record 表，这里必须拷贝字段
        local events = {}
        for _, pair in ipairs(record.events) do
            events[#events + 1] = { pair[1], pair[2] }
        end
        records[#records + 1] = { level = record.level, msg = record.msg, events = events }
    end
    local imports = {
        ["skyext.log.bucket"] = {
            new = function()
                return fake_bucket
            end,
            get_default = function()
                return fake_bucket
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    local mod = assert(loadfile(source, "t", env))()
    local lg = mod.new()
    lg:config({
        name = "redact_test",
        level = opts.level or log_level.DEBUG,
        log_src = false,
        log_table = opts.log_table,
        traceback = opts.traceback or function()
            return "<traceback>"
        end,
    })
    return lg, records
end

-- logger:error 目前把 traceback 放在 kv 的 key 位置，所以统一按 pair 取值
local function event_value(record, key)
    for _, pair in ipairs(record.events) do
        if pair[1] == key then
            return pair[2]
        end
    end
end

local function dump_events(record)
    local parts = {}
    for _, pair in ipairs(record.events) do
        parts[#parts + 1] = tostring(pair[1]) .. "=" .. tostring(pair[2])
    end
    return table.concat(parts, "\n")
end

t.describe("logger redaction", function()
    t.it("masks values whose key names a credential", function()
        local lg = spy_logger()
        local events = lg:_pack_events(log_level.INFO, "token", "eyJhbGciOi", "account", "abc")
        t.expect(events[1][1]).to.equal("token")
        t.expect(events[1][2]).to.equal("***REDACTED(len=10)***")
        t.expect(events[2][1]).to.equal("account")
        t.expect(events[2][2]).to.equal("abc")
    end)

    t.it("masks credentials nested inside a logged table", function()
        local lg, records = capture_logger()
        lg:info("request_uri end", "uri", "/v3/authenticate", "body", { token = "eyJhbGciOi", cluster_id = 7 })
        local body = event_value(records[1], "body")
        t.expect(body).to.be_type("string")
        t.expect(body:find("eyJhbGciOi", 1, true)).to.be_nil()
        t.expect(body:find("REDACTED", 1, true)).to.be_type("number")
        -- 非敏感字段照常输出，否则排障就没有信息了
        t.expect(body:find("cluster_id=7", 1, true)).to.be_type("number")
    end)

    t.it("does not treat an ordinary key as a credential", function()
        local lg = spy_logger()
        local events = lg:_pack_events(log_level.INFO, "key", "/skyext/node/role1", "keys", "k1", "monkey", "m")
        t.expect(events[1][2]).to.equal("/skyext/node/role1")
        t.expect(events[2][2]).to.equal("k1")
        t.expect(events[3][2]).to.equal("m")
    end)

    t.it("masks a credential before the table is ever serialized", function()
        -- log_table = false 时表本来就不展开，但敏感键仍然要变成占位串，
        -- 不能退化成 "table: 0x..." 之外还把原值带出去
        local lg, records = capture_logger({ log_table = false })
        lg:info("auth", "password", { plain = "hunter2" })
        t.expect(event_value(records[1], "password")).to.equal("***REDACTED***")
    end)

    t.it("masks credential arguments dumped by the C traceback", function()
        local fake = table.concat({
            "stack traceback:",
            "\n\t@lualib/skyext/etcd.lua:351: in function 'refresh'",
            '\n\t\t<arg 1> self = {user="root"}',
            '\n\t\t<arg 2> access_token = "eyJhbGciOiJIUzUxMiJ9.secret"',
            '\n\t\t<upvalue 1> login_jwt_secret = "your_access_secret"',
            '\n\t\t<upvalue 2> node_name = "role1"',
        })
        local lg, records = capture_logger({
            traceback = function()
                return fake
            end,
        })
        lg:error("boom", "k", "v")
        local dumped = dump_events(records[1])
        t.expect(dumped:find("eyJhbGciOiJIUzUxMiJ9.secret", 1, true)).to.be_nil()
        t.expect(dumped:find("your_access_secret", 1, true)).to.be_nil()
        -- 非敏感的栈信息保持不变
        t.expect(dumped:find("etcd.lua:351", 1, true)).to.be_type("number")
        t.expect(dumped:find('<upvalue 2> node_name = "role1"', 1, true)).to.be_type("number")
        t.expect(dumped:find("REDACTED", 1, true)).to.be_type("number")
    end)

    t.it("leaves a plain debug.traceback untouched", function()
        local plain = "stack traceback:\n\tlualib/skyext/etcd.lua:351: in function 'refresh'"
        local lg, records = capture_logger({
            traceback = function()
                return plain
            end,
        })
        lg:error("boom")
        t.expect(dump_events(records[1]):find(plain, 1, true)).to.be_type("number")
    end)
end)

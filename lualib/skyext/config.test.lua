local t = require "skytest"
local config = require "skyext.config"

t.describe("config.serialize", function()
    t.it("serializes numbers", function()
        t.expect(config.serialize(42)).to.equal("42")
        t.expect(config.serialize(0)).to.equal("0")
        t.expect(config.serialize(-1)).to.equal("-1")
    end)

    t.it("serializes strings with proper escaping", function()
        local result = config.serialize("hello")
        t.expect(result).to.contain("hello")
        -- string.format %q wraps in quotes
        t.expect(result:sub(1, 1)).to.equal('"')
    end)

    t.it("escapes special characters in strings", function()
        local result = config.serialize('has "quotes" and \\backslash')
        -- should not produce broken Lua when loaded
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        t.expect(fn()).to.equal('has "quotes" and \\backslash')
    end)

    t.it("escapes newlines in strings", function()
        local result = config.serialize("line1\nline2")
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        t.expect(fn()).to.equal("line1\nline2")
    end)

    t.it("serializes booleans", function()
        t.expect(config.serialize(true)).to.equal("true")
        t.expect(config.serialize(false)).to.equal("false")
    end)

    t.it("serializes simple tables", function()
        local result = config.serialize({ a = 1, b = "two" })
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        local tbl = fn()
        t.expect(tbl.a).to.equal(1)
        t.expect(tbl.b).to.equal("two")
    end)

    t.it("serializes nested tables", function()
        local result = config.serialize({ x = { y = 3 } })
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        local tbl = fn()
        t.expect(tbl.x.y).to.equal(3)
    end)

    t.it("serializes array-like tables", function()
        local result = config.serialize({ 1, 2, 3 })
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        local tbl = fn()
        t.expect(#tbl).to.equal(3)
        t.expect(tbl[1]).to.equal(1)
        t.expect(tbl[3]).to.equal(3)
    end)

    t.it("round-trips complex tables", function()
        local original = {
            name = "console",
            level = 5,
            nested = { a = true, b = { 1, 2 } },
        }
        local serialized = config.serialize(original)
        local fn = load("return " .. serialized)
        t.expect(fn).to.exist()
        local restored = fn()
        t.expect(restored.name).to.equal("console")
        t.expect(restored.level).to.equal(5)
        t.expect(restored.nested.a).to.equal(true)
        t.expect(restored.nested.b[2]).to.equal(2)
    end)
end)

t.describe("config.get", function()
    t.it("returns nil for unset keys", function()
        t.expect(config.get("__test_nonexistent_key__")).to.be_nil()
    end)
end)

-- 下面的用例要控制 skynet 环境变量和配置文件读取，所以不用上面那个全局实例，
-- 每次 harness 都 loadfile 出一份新的模块，内部的 conf 缓存从零开始
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/config.lua")

local function harness(env_values)
    local h = { env = env_values or {}, gets = {}, sets = {} }
    local imports = {
        skynet = {
            getenv = function(key)
                h.gets[key] = (h.gets[key] or 0) + 1
                return h.env[key]
            end,
            setenv = function(key, value)
                h.sets[key] = value
                h.env[key] = value
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.config = assert(loadfile(source, "t", env))()
    return h
end

t.describe("config.get 取值与缓存", function()
    t.it("第一次读环境变量，之后走缓存不再问 skynet", function()
        local h = harness({ key = "value" })
        t.expect(h.config.get("key")).to.equal("value")
        h.env.key = "changed"
        -- 缓存住了就不会看到后来的改动：配置是启动期快照，不是实时视图
        t.expect(h.config.get("key")).to.equal("value")
        t.expect(h.gets.key).to.equal(1)
    end)

    t.it("环境里没有的键返回 nil，且不写进缓存", function()
        local h = harness()
        t.expect(h.config.get("missing")).to.be_nil()
        t.expect(h.config.get("missing")).to.be_nil()
        t.expect(h.gets.missing).to.equal(2)
    end)
end)

t.describe("config.get_boolean", function()
    t.it("只有字符串 true 才算真，其余一律假", function()
        local h = harness({ a = "true", b = "false", c = "1", d = "yes", e = "TRUE" })
        t.expect(h.config.get_boolean("a")).to.equal(true)
        t.expect(h.config.get_boolean("b")).to.equal(false)
        -- "1"/"yes"/"TRUE" 看着像真，实际都是假；配置里只能写小写 true
        t.expect(h.config.get_boolean("c")).to.equal(false)
        t.expect(h.config.get_boolean("d")).to.equal(false)
        t.expect(h.config.get_boolean("e")).to.equal(false)
    end)

    t.it("缓存下来的 false 不会被当成未设置而重新读取", function()
        local h = harness({ flag = "false" })
        t.expect(h.config.get_boolean("flag")).to.equal(false)
        t.expect(h.config.get_boolean("flag")).to.equal(false)
        t.expect(h.gets.flag).to.equal(1)
    end)

    t.it("未设置的键返回 nil，能和显式的 false 区分开", function()
        local h = harness()
        t.expect(h.config.get_boolean("flag")).to.be_nil()
    end)
end)

t.describe("config.get_number", function()
    t.it("把字符串转成数字并缓存", function()
        local h = harness({ port = "8080", ratio = "1.5", neg = "-3" })
        t.expect(h.config.get_number("port")).to.equal(8080)
        t.expect(h.config.get_number("ratio")).to.equal(1.5)
        t.expect(h.config.get_number("neg")).to.equal(-3)
        h.config.get_number("port")
        t.expect(h.gets.port).to.equal(1)
    end)

    t.it("非数字的值返回 nil 而不是报错", function()
        local h = harness({ port = "abc" })
        t.expect(h.config.get_number("port")).to.be_nil()
        -- nil 存不进缓存表，于是每次都要重新问一遍 skynet
        t.expect(h.config.get_number("port")).to.be_nil()
        t.expect(h.gets.port).to.equal(2)
    end)

    t.it("未设置的键返回 nil", function()
        t.expect(harness().config.get_number("port")).to.be_nil()
    end)
end)

t.describe("config.get_table", function()
    t.it("把配置里的 Lua 表字面量求值成真正的表", function()
        local h = harness({ servers = '{ host = "a", ports = { 1, 2 } }' })
        local v = h.config.get_table("servers")
        t.expect(v.host).to.equal("a")
        t.expect(v.ports).to.equal({ 1, 2 })
    end)

    t.it("求值结果替换掉字符串缓存，第二次直接拿表", function()
        local h = harness({ servers = "{ 1 }" })
        local first = h.config.get_table("servers")
        local second = h.config.get_table("servers")
        t.expect(second).to.equal(first)
        -- 换成表之后 get_table 里的 type(s)=="string" 不再成立，不会重复 load
        t.expect(h.gets.servers).to.equal(1)
    end)

    t.it("未设置的键返回 nil，不去 load 空字符串", function()
        t.expect(harness().config.get_table("servers")).to.be_nil()
    end)

    t.it("语法不合法时报 load config failed 并带上原文", function()
        local h = harness({ servers = "{ { {" })
        t.expect(function()
            h.config.get_table("servers")
        end).to
            .throw("load config failed")
    end)

    t.it("求值过程抛错时报 exec config failed", function()
        local h = harness({ servers = 'error("boom")' })
        t.expect(function()
            h.config.get_table("servers")
        end).to
            .throw("exec config failed")
    end)
end)

t.describe("config.init", function()
    local function with_config(files, fn)
        local dir = fs.temporary_dir()
        for name, text in pairs(files) do
            fs.write(fs.join(dir, name), text)
        end
        local ok, err = pcall(fn, dir)
        fs.remove_tree(dir)
        if not ok then
            error(err, 0)
        end
    end

    t.it("把配置文件里的键值刷进 skynet 环境", function()
        with_config({ ["app.lua"] = 'name = "demo"\nport = 8080\nflag = true\n' }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            h.config.init()
            t.expect(h.sets.name).to.equal("demo")
            -- 环境变量只能存字符串，数字和布尔都要 tostring
            t.expect(h.sets.port).to.equal("8080")
            t.expect(h.sets.flag).to.equal("true")
        end)
    end)

    t.it("表类型的配置序列化后再写入，能被 get_table 读回来", function()
        with_config({ ["app.lua"] = 'db = { host = "127.0.0.1", port = 27017 }\n' }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            h.config.init()
            local db = h.config.get_table("db")
            t.expect(db.host).to.equal("127.0.0.1")
            t.expect(db.port).to.equal(27017)
        end)
    end)

    t.it("置上 app_config_loaded 防止重复加载", function()
        with_config({ ["app.lua"] = "a = 1\n" }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            h.config.init()
            t.expect(h.sets.app_config_loaded).to.equal("true")
        end)
    end)

    t.it("已经加载过就直接返回，不再碰配置文件", function()
        local h = harness({ app_config_loaded = "true", app_config_path = "/definitely/not/here.lua" })
        h.config.init()
        -- 路径是坏的，没报错就说明压根没去读
        t.expect(h.sets).to.equal({})
    end)

    t.it("没配 app_config_path 时报错，而不是静默跑一个空配置", function()
        local h = harness()
        t.expect(function()
            h.config.init()
        end).to
            .throw("app_config_path is nil")
    end)

    t.it("配置文件不存在时报 load app config failed", function()
        local h = harness({ app_config_path = "/definitely/not/here.lua" })
        t.expect(function()
            h.config.init()
        end).to
            .throw("load app config failed")
    end)

    t.it("配置文件语法错误时报 load app config failed", function()
        with_config({ ["app.lua"] = "a = = 1\n" }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            t.expect(function()
                h.config.init()
            end).to
                .throw("load app config failed")
        end)
    end)

    t.it("include 能加载同目录和子目录的配置", function()
        with_config({
            ["app.lua"] = 'include "sibling.lua"\ninclude "sub/deep.lua"\nmain = "m"\n',
            ["sibling.lua"] = 'sibling = "s"\n',
            ["sub/deep.lua"] = 'deep = "d"\n',
        }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            h.config.init()
            t.expect(h.sets.main).to.equal("m")
            t.expect(h.sets.sibling).to.equal("s")
            -- 子目录 include 之后要把 current_path 还原，否则后面的相对 include 会找错地方
            t.expect(h.sets.deep).to.equal("d")
        end)
    end)

    t.it("$VAR 指向未定义的环境变量时直接报错，不会悄悄留下字面量", function()
        with_config({ ["app.lua"] = 'home = "$SKYEXT_CONFIG_TEST_VAR"\n' }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            -- 错误里必须带上变量名，否则运维只能靠猜是哪一个没配
            t.expect(function()
                h.config.init()
            end).to
                .throw("SKYEXT_CONFIG_TEST_VAR")
        end)
    end)

    t.it("$VAR 指向真实存在的环境变量时取到它的值", function()
        with_config({ ["app.lua"] = 'p = "$PATH"\n' }, function(dir)
            local h = harness({ app_config_path = fs.join(dir, "app.lua") })
            h.config.init()
            t.expect(h.sets.p).to.equal(os.getenv("PATH"))
        end)
    end)
end)

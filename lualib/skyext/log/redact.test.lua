local t = require "skytest"
local redact = require "skyext.log.redact"

t.describe("redact.is_sensitive", function()
    -- expect 只收一个参数，循环断言失败时看不到是哪个 key，
    -- 所以先把结果收集成字符串再整体比较。
    local function report(keys, expected)
        local wrong = {}
        for _, key in ipairs(keys) do
            if redact.is_sensitive(key) ~= expected then
                wrong[#wrong + 1] = key
            end
        end
        return table.concat(wrong, ",")
    end

    t.it("matches credential key names case-insensitively and by substring", function()
        local keys = {
            "token",
            "jwt_token",
            "access_token",
            "refreshToken",
            "TOKEN",
            "login_jwt_secret",
            "client_secret",
            "password",
            "user_passwd",
            "Authorization",
            "authorization",
            "set-cookie",
            "credential",
            "credentials",
            "private_key",
            "access_key_id",
            "session_key",
            "api_key",
            "apiKey",
        }
        t.expect(report(keys, true)).to.equal("")
    end)

    t.it("does not treat ordinary keys as credentials", function()
        local keys = {
            "key", -- etcd 的 key 是业务数据
            "keys",
            "lock_key",
            "account",
            "rid",
            "keyword",
            "monkey",
            "body",
        }
        t.expect(report(keys, false)).to.equal("")
        -- 子串匹配的代价：名字里带敏感词的普通字段也会被打码。
        -- 宁可多打一个计数，也不能漏一个凭据。
        t.expect(redact.is_sensitive("fence_token_count")).to.equal(true)
        t.expect(redact.is_sensitive("secretary")).to.equal(true)
    end)

    t.it("returns false for non-string keys", function()
        t.expect(redact.is_sensitive(nil)).to.equal(false)
        t.expect(redact.is_sensitive(1)).to.equal(false)
        t.expect(redact.is_sensitive(true)).to.equal(false)
        t.expect(redact.is_sensitive({ "token" })).to.equal(false)
    end)
end)

t.describe("redact.mask", function()
    t.it("keeps the length of a string but not its content", function()
        t.expect(redact.mask("eyJhbGciOi")).to.equal("***REDACTED(len=10)***")
        t.expect(redact.mask("")).to.equal("***REDACTED(len=0)***")
    end)

    t.it("does not leak anything about non-string values", function()
        t.expect(redact.mask({ token = "x" })).to.equal(redact.MASK)
        t.expect(redact.mask(12345)).to.equal(redact.MASK)
        t.expect(redact.mask(nil)).to.equal(redact.MASK)
        t.expect(redact.mask(true)).to.equal(redact.MASK)
    end)
end)

t.describe("redact.filter_traceback", function()
    -- lualib-src/traceback.c 的输出格式：每条 arg/upvalue 记录占一行
    local function line(kind, index, name, value)
        return string.format("\n\t\t<%s %d> %s = %s", kind, index, name, value)
    end

    t.it("masks sensitive args and upvalues but keeps the rest of the frame", function()
        local input = table.concat({
            "stack traceback:",
            "\n\t@lualib/skyext/etcd.lua:351: in function 'refresh_jwt_token'",
            line("arg", 1, "self", '{user="root",password="***"}'),
            line("arg", 2, "timeout", "100"),
            line("upvalue", 1, "jwt_token", '"eyJhbGciOiJIUzUxMiJ9.payload.sig"'),
            line("upvalue", 2, "host", '"127.0.0.1:2379"'),
        })

        local out = redact.filter_traceback(input)
        t.expect(out:find("eyJhbGciOiJIUzUxMiJ9", 1, true)).to.be_nil()
        t.expect(out:find("REDACTED", 1, true)).to.be_type("number")
        -- 非敏感内容原样保留，否则堆栈就没法看了
        t.expect(out:find("etcd.lua:351", 1, true)).to.be_type("number")
        t.expect(out:find("<arg 2> timeout = 100", 1, true)).to.be_type("number")
        t.expect(out:find('<upvalue 2> host = "127.0.0.1:2379"', 1, true)).to.be_type("number")
        t.expect(out:find("<arg 1> self = ", 1, true)).to.be_type("number")
    end)

    t.it("masks a record that starts the string", function()
        local input = '\t\t<arg 1> access_token = "secret-value"'
        local out = redact.filter_traceback(input)
        t.expect(out:find("secret-value", 1, true)).to.be_nil()
        t.expect(out:find("REDACTED", 1, true)).to.be_type("number")
    end)

    t.it("passes through strings without records and non-strings", function()
        local plain = "stack traceback:\n\tlualib/skyext/etcd.lua:351: in function 'refresh'"
        t.expect(redact.filter_traceback(plain)).to.equal(plain)
        t.expect(redact.filter_traceback(nil)).to.be_nil()
        t.expect(redact.filter_traceback(42)).to.equal(42)
    end)
end)

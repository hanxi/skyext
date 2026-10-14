local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local cjson = require "cjson"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/gm_audit.lua")

local function harness(path)
    local h = { errors = {}, infos = {}, path = path }
    local imports = {
        skynet = {
            getenv = function(key)
                t.expect(key).to.equal("root")
                return "/nonexistent-root"
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("gm_audit_path")
                return h.path
            end,
        },
        ["skyext.time"] = {
            now = function()
                return 1700000000
            end,
            format = function(sec)
                return "T" .. sec
            end,
        },
        ["skyext.log"] = {
            info = function(...)
                h.infos[#h.infos + 1] = { ... }
            end,
            error = function(...)
                h.errors[#h.errors + 1] = { ... }
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.audit = assert(loadfile(source, "t", env))()
    return h
end

local function tmpfile()
    local path = os.tmpname()
    os.remove(path)
    return path
end

local function read_lines(path)
    local fh = assert(io.open(path, "r"))
    local lines = {}
    for line in fh:lines() do
        lines[#lines + 1] = cjson.decode(line)
    end
    fh:close()
    return lines
end

t.describe("gm audit record", function()
    t.it("appends one json line per operation", function()
        local path = tmpfile()
        local h = harness(path)
        h.audit.record({ account = "ops", role = "operator", peer = "10.0.0.1:5000", cmd = "gc", result = "ok" })
        h.audit.record({ account = "root", role = "admin", peer = "10.0.0.2:5001", cmd = "kill", result = "failed" })

        local lines = read_lines(path)
        t.expect(#lines).to.equal(2)
        t.expect(lines[1].account).to.equal("ops")
        t.expect(lines[1].cmd).to.equal("gc")
        t.expect(lines[1].result).to.equal("ok")
        t.expect(lines[1].time).to.equal("T1700000000")
        t.expect(lines[2].account).to.equal("root")
        t.expect(#h.errors).to.equal(0)
        os.remove(path)
    end)

    t.it("keeps credentials out of the record", function()
        local path = tmpfile()
        local h = harness(path)
        h.audit.record({
            account = "ops",
            role = "operator",
            cmd = "login",
            params = { token = "a1b2c3", password = "hunter2", secret = "s3cr3t", name = "role_db" },
            result = "ok",
        })

        local entry = read_lines(path)[1]
        t.expect(entry.params.token).to.equal("[redacted]")
        t.expect(entry.params.password).to.equal("[redacted]")
        t.expect(entry.params.secret).to.equal("[redacted]")
        t.expect(entry.params.name).to.equal("role_db")
        os.remove(path)
    end)

    t.it("stringifies and truncates parameter values", function()
        local path = tmpfile()
        local h = harness(path)
        h.audit.record({
            account = "ops",
            cmd = "inject",
            params = { long = string.rep("x", 400), nested = { 1, 2 }, count = 7 },
            result = "ok",
        })

        local entry = read_lines(path)[1]
        t.expect(#entry.params.long).to.equal(256 + 3)
        t.expect(entry.params.nested).to.equal("[table]")
        t.expect(entry.params.count).to.equal("7")
        os.remove(path)
    end)

    t.it("omits params entirely when the command takes none", function()
        local path = tmpfile()
        local h = harness(path)
        h.audit.record({ account = "ops", cmd = "list", params = {}, result = "ok" })
        t.expect(read_lines(path)[1].params).to.be_nil()
        os.remove(path)
    end)

    t.it("reports a write failure but still records in memory", function()
        -- 目录不存在，io.open 必然失败：磁盘出问题不能让 GM 指令跟着挂掉
        local h = harness("/nonexistent-dir/gm_audit.jsonl")
        h.audit.record({ account = "ops", cmd = "gc", result = "ok" })
        t.expect(#h.errors).to.equal(1)
        t.expect(h.errors[1][1]).to.equal("GM audit write failed")
        t.expect(#h.audit.recent()).to.equal(1)
    end)

    t.it("logs every record so it also shows up in the normal log", function()
        local h = harness("/nonexistent-dir/gm_audit.jsonl")
        h.audit.record({ account = "ops", peer = "10.0.0.1:5000", cmd = "gc", result = "ok" })
        t.expect(h.infos[1][1]).to.equal("GM audit")
    end)
end)

t.describe("gm audit recent", function()
    t.it("returns the newest records first and caps the list", function()
        local h = harness("/nonexistent-dir/gm_audit.jsonl")
        for i = 1, 5 do
            h.audit.record({ account = "ops", cmd = "cmd" .. i, result = "ok" })
        end

        local recent = h.audit.recent()
        t.expect(#recent).to.equal(5)
        t.expect(recent[1].cmd).to.equal("cmd5")
        t.expect(recent[5].cmd).to.equal("cmd1")
        t.expect(#h.audit.recent(2)).to.equal(2)
        t.expect(h.audit.recent(2)[1].cmd).to.equal("cmd5")
    end)

    t.it("never grows past the in-memory limit", function()
        local h = harness("/nonexistent-dir/gm_audit.jsonl")
        for i = 1, 120 do
            h.audit.record({ account = "ops", cmd = "cmd" .. i, result = "ok" })
        end
        t.expect(#h.audit.recent(1000)).to.equal(100)
        t.expect(h.audit.recent(1)[1].cmd).to.equal("cmd120")
    end)
end)

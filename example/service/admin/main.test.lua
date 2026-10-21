local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/service/admin/main.lua")

local function harness()
    local h = {}
    local imports = {
        skynet = {
            start = function(f)
                f()
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.GM = cmds
            end,
        },
        ["skyext.entity.router"] = {
            reliable_send = function(...)
                h.reliable = table.pack(...)
                return 4242
            end,
        },
        ["skyext.time"] = {
            now_ms = function()
                return 1000
            end,
        },
        role_db_api = {
            exists = function(rid)
                return rid == 7
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    return h
end

t.describe("admin GM send_mail", function()
    t.it("sends a system mail with an attachment through a reliable message", function()
        local h = harness()
        local ok, msg_id = h.GM.send_mail.handler({
            rid = "7",
            title = "补偿",
            content = "服务器维护补偿",
            res_type = "101",
            res_id = "10086",
            res_size = "5",
        })
        t.expect(ok).to.equal(true)
        t.expect(msg_id).to.equal(4242)
        t.expect(h.reliable[1]).to.equal("role")
        t.expect(h.reliable[2]).to.equal(7)
        t.expect(h.reliable[3]).to.equal("recv_mail")
        local mail = h.reliable[4][1]
        t.expect(mail.title).to.equal("补偿")
        t.expect(mail.attach).to.equal({ { res_type = 101, res_id = 10086, res_size = 5 } })
    end)

    t.it("rejects a missing role, a missing title and a bad attachment", function()
        local h = harness()
        t.expect(table.pack(h.GM.send_mail.handler({ rid = "8", title = "x" }))).to.equal({
            false,
            "role not found",
            n = 2,
        })
        t.expect((h.GM.send_mail.handler({ rid = "7" }))).to.equal(false)
        t.expect((h.GM.send_mail.handler({ rid = "7", title = "x", res_type = "1", res_size = "0" }))).to.equal(false)
        t.expect(h.reliable).to.be_nil()
    end)
end)

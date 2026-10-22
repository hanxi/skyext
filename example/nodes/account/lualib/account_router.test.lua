local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local errcode = require "errcode"

local source = fs.join(
    fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()),
    "example/nodes/account/lualib/account_router.lua"
)

local VALID_TOKEN = "good-token"

-- 整个路由只依赖 DB/JWT/配置表这几个外部模块，全部换成内存假件；
-- 断言的是路由自己的决策：鉴权取哪儿、坏 body 怎么回、名额在失败路径上还不还
local function harness(opts)
    opts = opts or {}
    local h = { released = 0, reserved = 0, created = {}, names = {} }
    local imports = {
        ["skyext.log"] = setmetatable({}, {
            __index = function()
                return function() end
            end,
        }),
        ["skyext.config"] = {
            get_boolean = function(key)
                return key == "dev_login_enable" and opts.dev_login ~= false
            end,
            get_number = function(key)
                return key == "max_role_count" and (opts.max_role_count or 2) or nil
            end,
        },
        jwt = {
            verify_login = function(token)
                if token ~= VALID_TOKEN then
                    return nil, "bad token", "token"
                end
                return { account = "alice" }
            end,
            sign_login = function()
                return VALID_TOKEN
            end,
        },
        role_db_api = {
            get_roles = function(_, query)
                local roles = {}
                for rid, doc in pairs(h.created) do
                    if (not query.rid or query.rid == rid) and (not query.server or query.server == doc.server) then
                        roles[#roles + 1] = { rid = rid, server = doc.server, name = doc.name }
                    end
                end
                return roles
            end,
            create = function(rid, _, doc)
                if opts.create_fails then
                    return nil
                end
                h.created[rid] = doc
                return true
            end,
        },
        user_db_api = {
            ensure_get_user = function()
                return { account = "alice" }
            end,
            reserve_role_slot = function(_, _, max)
                if opts.reserve_fails then
                    return nil, "db down"
                end
                if h.reserved - h.released >= max then
                    return false
                end
                h.reserved = h.reserved + 1
                return true
            end,
            release_role_slot = function()
                h.released = h.released + 1
            end,
        },
        ["skyext.id_generator"] = {
            newid = function()
                h.next_rid = (h.next_rid or 100) + 1
                return h.next_rid
            end,
        },
        ["skyext.time"] = {
            now_ms = function()
                return 1000
            end,
        },
        role_name_api = {
            reserve = function(server, name)
                local key = server .. "/" .. name
                if h.names[key] then
                    return false, "taken"
                end
                h.names[key] = true
                return true
            end,
            release = function(server, name)
                h.names[server .. "/" .. name] = nil
            end,
        },
        ["skyext.realm"] = {
            server = function(name)
                return name == "s1" and { name = "一区", status = "open" } or nil
            end,
            servers = function()
                return { "s1" }
            end,
            tag_of = function()
                return "S1"
            end,
        },
        -- 策划配置表：路由每次校验名字都现读 NameLimit
        ["skyext.res"] = { param = { NameLimit = opts.name_limit or 8 } },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.router = assert(loadfile(source, "t", env))()

    -- 调一个路由，返回 { status, body }。req 只实现 http_server/agent.lua 暴露的那几个方法
    function h.call(method, path, req)
        req = req or {}
        local out = {}
        local request = {
            path = path,
            header = req.header or {},
            parse_query = function()
                return req.query or {}
            end,
            read_json = function()
                if req.body == nil then
                    return nil, "empty body"
                end
                if type(req.body) ~= "table" then
                    return nil, "body is not a json object"
                end
                return req.body
            end,
        }
        local response = {
            write = function(status, body)
                out.status, out.body = status, body
            end,
            write_json = function(body)
                out.status, out.body = 200, body
            end,
        }
        h.router[method][path](request, response)
        return out
    end

    function h.bearer(token)
        return { authorization = "Bearer " .. token }
    end

    function h.create_role(name, server, token)
        return h.call("POST", "/create_role", {
            header = h.bearer(token or VALID_TOKEN),
            body = { server = server or "s1", name = name },
        })
    end
    return h
end

t.describe("account router auth", function()
    t.it("takes the login token from the Authorization header, not the query string", function()
        local h = harness()
        t.expect(h.call("GET", "/roles", { query = { token = VALID_TOKEN } }).body.code).to.equal(errcode.TOKEN_ERROR)
        t.expect(h.call("GET", "/roles", { header = h.bearer(VALID_TOKEN) }).body.code).to.equal(errcode.OK)
    end)

    t.it("accepts the Bearer scheme case-insensitively and rejects a malformed header", function()
        local h = harness()
        t.expect(h.call("GET", "/roles", { header = { authorization = "bearer " .. VALID_TOKEN } }).body.code).to
            .equal(errcode.OK)
        t.expect(h.call("GET", "/roles", { header = { authorization = VALID_TOKEN } }).body.code).to
            .equal(errcode.TOKEN_ERROR)
        -- 同名头出现多次时 httpd 给的是 table，不能当字符串去 match
        t.expect(h.call("GET", "/roles", { header = { authorization = { "Bearer a", "Bearer b" } } }).body.code).to
            .equal(errcode.TOKEN_ERROR)
    end)
end)

t.describe("account router request body", function()
    t.it("answers PARAM_ERROR instead of crashing on an empty or non-object body", function()
        local h = harness()
        t.expect(h.call("POST", "/create_role", { header = h.bearer(VALID_TOKEN) }).body.code).to
            .equal(errcode.PARAM_ERROR)
        t.expect(h.call("POST", "/create_role", { header = h.bearer(VALID_TOKEN), body = "not json" }).body.code).to
            .equal(errcode.PARAM_ERROR)
        t.expect(h.call("POST", "/dev_login", {}).body.code).to.equal(errcode.PARAM_ERROR)
    end)

    t.it("checks the token before it ever looks at the body", function()
        local h = harness()
        t.expect(h.call("POST", "/create_role", { body = { server = "s1", name = "a" } }).body.code).to
            .equal(errcode.TOKEN_ERROR)
    end)
end)

t.describe("account router create_role", function()
    t.it("creates a role and reports it back", function()
        local h = harness()
        local out = h.create_role("alice")
        t.expect(out.body.code).to.equal(errcode.OK)
        t.expect(out.body.role.name).to.equal("alice")
        t.expect(out.body.role.server).to.equal("s1")
    end)

    t.it("takes the name length limit from the res table", function()
        local h = harness({ name_limit = 4 })
        t.expect(h.create_role("abcde").body.code).to.equal(errcode.PARAM_ERROR)
        t.expect(h.create_role("abcd").body.code).to.equal(errcode.OK)
        t.expect(h.create_role("").body.code).to.equal(errcode.PARAM_ERROR)
        t.expect(h.create_role("a\nb").body.code).to.equal(errcode.PARAM_ERROR)
    end)

    t.it("enforces the per-server role limit", function()
        local h = harness({ max_role_count = 2 })
        t.expect(h.create_role("r1").body.code).to.equal(errcode.OK)
        t.expect(h.create_role("r2").body.code).to.equal(errcode.OK)
        t.expect(h.create_role("r3").body.code).to.equal(errcode.ROLE_TOO_MANY)
    end)

    t.it("gives the slot back when the name is taken", function()
        local h = harness({ max_role_count = 5 })
        t.expect(h.create_role("dup").body.code).to.equal(errcode.OK)
        t.expect(h.create_role("dup").body.code).to.equal(errcode.NAME_TAKEN)
        -- 占名失败那次必须把名额还回去，否则玩家平白少一个格子
        t.expect(h.reserved - h.released).to.equal(1)
    end)

    t.it("gives the slot and the name back when the insert fails", function()
        local h = harness({ create_fails = true })
        t.expect(h.create_role("ghost").body.code).to.equal(errcode.DB_ERROR)
        t.expect(h.reserved - h.released).to.equal(0)
        t.expect(next(h.names)).to.be_nil()
    end)

    t.it("refuses a server that is not in the realm directory", function()
        local h = harness()
        t.expect(h.create_role("alice", "s9").body.code).to.equal(errcode.SERVER_NOT_EXIST)
        t.expect(h.reserved).to.equal(0)
    end)
end)

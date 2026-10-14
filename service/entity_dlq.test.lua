local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/entity_dlq.lua")

-- GM 参数经 HTTP query/body 传进来全是字符串，这里的假实现只接受已经转换好的类型，
-- 服务层漏了转换就会在断言上暴露，而不是悄悄查不到数据
local function harness()
    local h = { dead = {}, pokes = {} }

    local fake_msg = {}
    function fake_msg.list_dead(opts)
        h.list_opts = opts
        if h.list_error then
            error(h.list_error)
        end
        local out = {}
        for _, doc in ipairs(h.dead) do
            local hit = (opts.target_type == nil or doc.target_type == opts.target_type)
                and (opts.target_id == nil or doc.target_id == opts.target_id)
            if hit then
                out[#out + 1] = doc
            end
        end
        return out
    end
    function fake_msg.replay(msg_id)
        h.replayed = msg_id
        if h.replay_error then
            error(h.replay_error)
        end
        for _, doc in ipairs(h.dead) do
            if doc.msg_id == msg_id then
                return doc
            end
        end
        return nil, "not_dead"
    end
    function fake_msg.discard(msg_id, operator)
        h.discarded = { msg_id = msg_id, operator = operator }
        if h.discard_error then
            error(h.discard_error)
        end
        for _, doc in ipairs(h.dead) do
            if doc.msg_id == msg_id then
                return true
            end
        end
        return false, "not_dead"
    end

    local fake_router = {}
    function fake_router.poke_reliable(target_type, target_id)
        h.pokes[#h.pokes + 1] = { target_type, target_id }
        return h.poke_ok ~= false
    end

    local noop = function() end
    local imports = {
        skynet = setmetatable({
            start = function(f)
                f()
            end,
        }, { __index = skynet }),
        ["skyext.cmd_api"] = { dispatch = noop },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.cmds = cmds
            end,
        },
        ["skyext.entity.reliable_msg"] = fake_msg,
        ["skyext.entity.router"] = fake_router,
        ["skyext.log"] = { info = noop, warn = noop, error = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    assert(h.cmds, "entity_dlq did not register GM commands")
    return h
end

local function run(h, cmd, params)
    return h.cmds[cmd].handler(params)
end

t.describe("entity_dlq GM 指令", function()
    t.it("注册了死信队列的三条指令，且都带 desc 与 handler", function()
        local h = harness()
        for _, name in ipairs({ "dlq_list", "dlq_replay", "dlq_discard" }) do
            local def = h.cmds[name]
            t.expect(def).to.be_type("table")
            t.expect(def.desc).to.be_type("string")
            t.expect(def.handler).to.be_type("function")
        end
    end)

    t.describe("dlq_list", function()
        t.it("返回条数与精简字段", function()
            local h = harness()
            h.dead = {
                {
                    msg_id = 11,
                    seq = 1,
                    target_type = "role",
                    target_id = 7,
                    cmd = "add_item",
                    attempts = 5,
                    create_time = 100,
                    dead_time = 200,
                    dead_reason = "boom",
                    args = { 1, 2 },
                },
            }
            local ok, data = run(h, "dlq_list", {})
            t.expect(ok).to.equal(true)
            t.expect(data.count).to.equal(1)
            t.expect(data.messages[1]).to.equal({
                msg_id = 11,
                seq = 1,
                target_type = "role",
                target_id = 7,
                cmd = "add_item",
                attempts = 5,
                create_time = 100,
                dead_time = 200,
                dead_reason = "boom",
            })
        end)

        -- args 是业务负载，可能带玩家数据，不该经 GM 接口整份吐出来
        t.it("不返回消息体 args", function()
            local h = harness()
            h.dead = { { msg_id = 11, target_type = "role", target_id = 7, args = { "secret" } } }
            local _, data = run(h, "dlq_list", {})
            t.expect(data.messages[1].args).to.be_nil()
        end)

        t.it("把字符串参数转换成查询需要的类型", function()
            local h = harness()
            run(h, "dlq_list", { target_type = "role", target_id = "7", limit = "20" })
            t.expect(h.list_opts.target_type).to.equal("role")
            t.expect(h.list_opts.target_id).to.equal(7)
            t.expect(h.list_opts.limit).to.equal(20)
        end)

        t.it("非数字的 target_id 原样传下去", function()
            local h = harness()
            run(h, "dlq_list", { target_id = "guild-a" })
            t.expect(h.list_opts.target_id).to.equal("guild-a")
        end)

        t.it("空串参数等同于不过滤", function()
            local h = harness()
            run(h, "dlq_list", { target_type = "", target_id = "", limit = "" })
            t.expect(h.list_opts.target_type).to.be_nil()
            t.expect(h.list_opts.target_id).to.be_nil()
            t.expect(h.list_opts.limit).to.be_nil()
        end)

        t.it("没有参数时也能执行", function()
            local h = harness()
            local ok, data = run(h, "dlq_list", nil)
            t.expect(ok).to.equal(true)
            t.expect(data.count).to.equal(0)
        end)

        t.it("非法 limit 被拒绝且不查库", function()
            local h = harness()
            local ok, err = run(h, "dlq_list", { limit = "0" })
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("invalid limit")
            t.expect(h.list_opts).to.be_nil()
        end)

        -- GM 指令抛错会把结果变成一条看不懂的 traceback，这里转成可读的失败
        t.it("查库抛错时返回失败而不是把异常抛给 GM 调用方", function()
            local h = harness()
            h.list_error = "mongo down"
            local ok, err = run(h, "dlq_list", {})
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("mongo down")
        end)
    end)

    t.describe("dlq_replay", function()
        t.it("重放成功后唤醒目标实体并返回目标信息", function()
            local h = harness()
            h.dead = { { msg_id = 11, target_type = "role", target_id = 7, cmd = "add_item" } }
            local ok, data = run(h, "dlq_replay", { msg_id = "11" })
            t.expect(ok).to.equal(true)
            t.expect(data).to.equal({
                msg_id = 11,
                target_type = "role",
                target_id = 7,
                cmd = "add_item",
                poked = true,
            })
            t.expect(h.pokes).to.equal({ { "role", 7 } })
        end)

        -- 消息已经回到 pending，实体加载或重试定时器会接上，唤醒失败不该报错
        t.it("唤醒失败仍算重放成功，只是标记 poked = false", function()
            local h = harness()
            h.dead = { { msg_id = 11, target_type = "role", target_id = 7, cmd = "add_item" } }
            h.poke_ok = false
            local ok, data = run(h, "dlq_replay", { msg_id = "11" })
            t.expect(ok).to.equal(true)
            t.expect(data.poked).to.equal(false)
        end)

        t.it("不是死信时返回失败原因", function()
            local h = harness()
            local ok, err = run(h, "dlq_replay", { msg_id = "11" })
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("not_dead")
            t.expect(h.pokes).to.equal({})
        end)

        t.it("缺少或非法的 msg_id 被拒绝且不动数据", function()
            local h = harness()
            for _, bad in ipairs({ {}, { msg_id = "" }, { msg_id = "abc" }, { msg_id = "1.5" } }) do
                local ok = run(h, "dlq_replay", bad)
                t.expect(ok).to.equal(false)
            end
            t.expect(h.replayed).to.be_nil()
        end)

        t.it("重放抛错时返回失败", function()
            local h = harness()
            h.replay_error = "mongo down"
            local ok, err = run(h, "dlq_replay", { msg_id = "11" })
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("mongo down")
        end)
    end)

    t.describe("dlq_discard", function()
        t.it("丢弃成功并把操作人透传下去", function()
            local h = harness()
            h.dead = { { msg_id = 11, target_type = "role", target_id = 7 } }
            local ok, data = run(h, "dlq_discard", { msg_id = "11", operator = "alice" })
            t.expect(ok).to.equal(true)
            t.expect(data).to.equal({ msg_id = 11 })
            t.expect(h.discarded).to.equal({ msg_id = 11, operator = "alice" })
        end)

        t.it("不是死信时返回失败原因", function()
            local h = harness()
            local ok, err = run(h, "dlq_discard", { msg_id = "11" })
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("not_dead")
        end)

        t.it("缺少 msg_id 被拒绝且不动数据", function()
            local h = harness()
            local ok, err = run(h, "dlq_discard", {})
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("msg_id is required")
            t.expect(h.discarded).to.be_nil()
        end)

        t.it("丢弃抛错时返回失败", function()
            local h = harness()
            h.discard_error = "mongo down"
            local ok, err = run(h, "dlq_discard", { msg_id = "11" })
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("mongo down")
        end)
    end)
end)

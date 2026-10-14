local t = require "skytest"
local skynet = require "skynet"

-- 用内存假 mongo 替换 skyext.mongo_conn，验证可靠消息的投递语义与查询参数。
-- 假实现只支持 reliable_msg 用到的查询算子（等值 + $gt），遇到其它算子直接报错，
-- 这样真实代码一旦改成别的查询方式，测试会立刻暴露而不是悄悄通过。

local function copy(v)
    if type(v) ~= "table" then
        return v
    end
    local r = {}
    for k, vv in pairs(v) do
        r[k] = copy(vv)
    end
    return r
end

local function match(doc, query)
    for k, cond in pairs(query) do
        local dv = doc[k]
        if type(cond) == "table" then
            for op, ov in pairs(cond) do
                if op == "$gt" then
                    if type(dv) ~= "number" or dv <= ov then
                        return false
                    end
                else
                    error("fake mongo: unsupported query operator " .. tostring(op))
                end
            end
        elseif dv ~= cond then
            return false
        end
    end
    return true
end

local env = {}

local function new_coll(name)
    local coll = { name = name, docs = {}, calls = {} }

    local function log_call(op, a, b)
        coll.calls[#coll.calls + 1] = { op = op, a = copy(a), b = copy(b) }
    end

    function coll:safe_insert(doc)
        log_call("safe_insert", doc)
        if env.insert_error then
            return false, env.insert_error
        end
        self.docs[#self.docs + 1] = copy(doc)
        return true, nil, { ok = 1, n = 1 }
    end

    function coll:find_many(query, opts)
        log_call("find_many", query, opts)
        opts = opts or {}
        local hit = {}
        for i, doc in ipairs(self.docs) do
            if match(doc, query) then
                hit[#hit + 1] = { doc = doc, idx = i }
            end
        end
        if opts.sort then
            local key, dir = next(opts.sort)
            assert(next(opts.sort, key) == nil, "fake mongo: only single-key sort supported")
            table.sort(hit, function(x, y)
                local a, b = x.doc[key], y.doc[key]
                if a == b then
                    return x.idx < y.idx
                end
                if dir == 1 then
                    return a < b
                end
                return a > b
            end)
        end
        local out = {}
        local skip = opts.skip or 0
        for i = skip + 1, #hit do
            if opts.limit and #out >= opts.limit then
                break
            end
            out[#out + 1] = copy(hit[i].doc)
        end
        return out
    end

    function coll:find_one(query)
        log_call("find_one", query)
        for _, doc in ipairs(self.docs) do
            if match(doc, query) then
                return copy(doc)
            end
        end
    end

    function coll:find_and_modify(doc)
        log_call("find_and_modify", doc)
        assert(doc.query, "findAndModify requires query")
        assert(doc.update or doc.remove, "findAndModify requires update or remove")
        if env.fam_error and env.fam_error[self.name] then
            return { ok = 0, errmsg = env.fam_error[self.name] }
        end
        -- 模拟服务端串行：让出一次再做修改，整个读-改-写在一个调用内完成且不再让出
        if env.yield_in_fam then
            skynet.sleep(0)
        end
        local target
        for _, d in ipairs(self.docs) do
            if match(d, doc.query) then
                target = d
                break
            end
        end
        local old
        if not target then
            if not doc.upsert then
                return { ok = 1, value = nil }
            end
            target = {}
            for k, v in pairs(doc.query) do
                if type(v) ~= "table" then
                    target[k] = v
                end
            end
            self.docs[#self.docs + 1] = target
        else
            old = copy(target)
        end
        local update = doc.update
        for op, fields in pairs(update) do
            if op == "$inc" then
                for k, v in pairs(fields) do
                    target[k] = (target[k] or 0) + v
                end
            elseif op == "$set" then
                for k, v in pairs(fields) do
                    target[k] = v
                end
            elseif op == "$unset" then
                for k in pairs(fields) do
                    target[k] = nil
                end
            else
                error("fake mongo: unsupported update operator " .. tostring(op))
            end
        end
        return { ok = 1, value = doc.new and copy(target) or old }
    end

    return coll
end

local fake_mongo = { colls = {} }
function fake_mongo.get_collection(db, coll)
    local key = db .. "." .. coll
    local c = fake_mongo.colls[key]
    if not c then
        c = new_coll(coll)
        fake_mongo.colls[key] = c
    end
    return c
end

local next_fake_id = 0
local fake_idgen = {}
function fake_idgen.newid()
    -- 故意递减：msg_id 的大小不代表分配先后（真实 id_generator 走哈希缓存池，发放无序）
    next_fake_id = next_fake_id + 1
    return 1000000 - next_fake_id
end

-- 真实 config 读的是 skynet 环境变量，一个 key 只能 setenv 一次，
-- 测不了"同一进程里换不同上限"，因此直接替掉
local config_values = {}
local fake_config = {}
function fake_config.get_number(key)
    return config_values[key]
end

package.loaded["skyext.mongo_conn"] = fake_mongo
package.loaded["skyext.id_generator"] = fake_idgen
package.loaded["skyext.config"] = fake_config

local reliable_msg = require "skyext.entity.reliable_msg"

local SEQ = "entity.entity_msg_seq"

local function msg_coll()
    return fake_mongo.get_collection("entity", "entity_msg")
end

local function reset()
    fake_mongo.colls = {}
    next_fake_id = 0
    env.insert_error = nil
    env.fam_error = nil
    env.yield_in_fam = nil
    config_values = {}
    -- 预创建，保证 calls 记录从干净状态开始
    fake_mongo.get_collection("entity", "entity_msg")
    fake_mongo.get_collection("entity", "entity_msg_seq")
end

local function calls_of(coll, op)
    local r = {}
    for _, c in ipairs(coll.calls) do
        if c.op == op then
            r[#r + 1] = c
        end
    end
    return r
end

t.describe("reliable_msg", function()
    t.before_each(reset)

    t.describe("ID 分配", function()
        t.before_each(reset)

        t.it("按 (target_type, target_id) 维度原子自增分配 seq", function()
            local _, s1 = reliable_msg.save("role", 1, "cmd_a", {})
            local _, s2 = reliable_msg.save("role", 1, "cmd_b", {})
            local _, s3 = reliable_msg.save("role", 2, "cmd_c", {})
            local _, s4 = reliable_msg.save("guild", 1, "cmd_d", {})
            t.expect(s1).to.equal(1)
            t.expect(s2).to.equal(2)
            t.expect(s3).to.equal(1)
            t.expect(s4).to.equal(1)
        end)

        t.it("分配使用 findAndModify($inc + upsert + new)，不是读-改-写", function()
            reliable_msg.save("role", 7, "cmd", {})
            local fam = calls_of(fake_mongo.colls[SEQ], "find_and_modify")
            t.expect(#fam).to.equal(1)
            local doc = fam[1].a
            t.expect(doc.query._id).to.equal("role:7")
            t.expect(doc.update["$inc"].seq).to.equal(1)
            t.expect(doc.upsert).to.equal(true)
            t.expect(doc.new).to.equal(true)
            -- 没有额外的读接口参与分配
            t.expect(#calls_of(fake_mongo.colls[SEQ], "find_many")).to.equal(0)
            t.expect(#calls_of(fake_mongo.colls[SEQ], "find_one")).to.equal(0)
        end)

        t.it("并发 save 不会重号，seq 连续且唯一", function()
            env.yield_in_fam = true
            local total = 20
            local done = 0
            local seqs = {}
            for i = 1, total do
                skynet.fork(function()
                    local _, seq = reliable_msg.save("role", 99, "cmd" .. i, {})
                    seqs[#seqs + 1] = seq
                    done = done + 1
                end)
            end
            while done < total do
                skynet.sleep(1)
            end
            t.expect(#seqs).to.equal(total)
            local seen = {}
            for _, s in ipairs(seqs) do
                t.expect(seen[s]).to.be_nil()
                seen[s] = true
            end
            for i = 1, total do
                t.expect(seen[i]).to.equal(true)
            end
            t.expect(#msg_coll().docs).to.equal(total)
        end)

        t.it("seq 分配失败时抛错且不落消息", function()
            env.fam_error = { entity_msg_seq = "counter down" }
            t.expect(function()
                reliable_msg.save("role", 1, "cmd", {})
            end).to
                .throw("alloc seq failed")
            t.expect(#msg_coll().docs).to.equal(0)
        end)

        t.it("写入失败时 save 抛错，调用方不会误以为已持久化", function()
            env.insert_error = "disk full"
            t.expect(function()
                reliable_msg.save("role", 1, "cmd", {})
            end).to
                .throw("disk full")
        end)
    end)

    t.describe("load_pending 排序与分页", function()
        t.before_each(reset)

        t.it("按 seq 升序返回，与 msg_id 大小无关", function()
            local ids = {}
            for i = 1, 5 do
                ids[i] = reliable_msg.save("role", 1, "cmd" .. i, { i })
            end
            -- msg_id 是递减的，若按 msg_id 排序顺序会反过来
            t.expect(ids[1]).to.be_gt(ids[5])
            -- 打乱物理存储顺序，证明排序来自查询而不是插入顺序
            local docs = msg_coll().docs
            docs[1], docs[4] = docs[4], docs[1]
            docs[2], docs[5] = docs[5], docs[2]

            local msgs = reliable_msg.load_pending("role", 1)
            t.expect(#msgs).to.equal(5)
            for i = 1, 5 do
                t.expect(msgs[i].seq).to.equal(i)
                t.expect(msgs[i].cmd).to.equal("cmd" .. i)
            end
        end)

        t.it("排序参数走 find_many 的 opts.sort，不会被当成 projection", function()
            reliable_msg.save("role", 1, "cmd", {})
            msg_coll().calls = {}
            reliable_msg.load_pending("role", 1)
            local find = calls_of(msg_coll(), "find_many")
            t.expect(#find).to.equal(1)
            t.expect(find[1].b.sort).to.equal({ seq = 1 })
            t.expect(find[1].b.projection).to.be_nil()
            t.expect(find[1].b.limit).to.equal(reliable_msg.DEFAULT_PAGE_SIZE)
            t.expect(find[1].a.status).to.equal(reliable_msg.STATUS_PENDING)
            t.expect(find[1].a.target_type).to.equal("role")
            t.expect(find[1].a.target_id).to.equal(1)
        end)

        t.it("只返回本目标的 pending 消息", function()
            local id1 = reliable_msg.save("role", 1, "a", {})
            reliable_msg.save("role", 2, "b", {})
            reliable_msg.save("guild", 1, "c", {})
            reliable_msg.save("role", 1, "d", {})
            reliable_msg.mark_delivered(id1)

            local msgs = reliable_msg.load_pending("role", 1)
            t.expect(#msgs).to.equal(1)
            t.expect(msgs[1].cmd).to.equal("d")
        end)

        t.it("分页使用 seq > last_seq 的 keyset 翻页，不重不漏", function()
            for i = 1, 250 do
                reliable_msg.save("role", 1, "cmd" .. i, {})
            end
            msg_coll().calls = {}

            local msgs = reliable_msg.load_pending("role", 1, { page_size = 100 })
            t.expect(#msgs).to.equal(250)
            for i = 1, 250 do
                t.expect(msgs[i].seq).to.equal(i)
            end

            local find = calls_of(msg_coll(), "find_many")
            t.expect(#find).to.equal(3)
            t.expect(find[1].a.seq).to.be_nil()
            t.expect(find[2].a.seq).to.equal({ ["$gt"] = 100 })
            t.expect(find[3].a.seq).to.equal({ ["$gt"] = 200 })
            for _, c in ipairs(find) do
                t.expect(c.b.limit).to.equal(100)
                t.expect(c.b.skip).to.be_nil()
            end
        end)

        t.it("整页命中后多查一次确认结束", function()
            for i = 1, 200 do
                reliable_msg.save("role", 1, "cmd" .. i, {})
            end
            msg_coll().calls = {}
            local msgs = reliable_msg.load_pending("role", 1, { page_size = 100 })
            t.expect(#msgs).to.equal(200)
            t.expect(#calls_of(msg_coll(), "find_many")).to.equal(3)
        end)

        t.it("max_count 限制总条数并收敛每批 limit", function()
            for i = 1, 100 do
                reliable_msg.save("role", 1, "cmd" .. i, {})
            end
            msg_coll().calls = {}
            local msgs = reliable_msg.load_pending("role", 1, { page_size = 30, max_count = 50 })
            t.expect(#msgs).to.equal(50)
            t.expect(msgs[50].seq).to.equal(50)
            local find = calls_of(msg_coll(), "find_many")
            t.expect(find[#find].b.limit).to.be_lte(30)
        end)

        t.it("after_seq 可以从指定位置继续", function()
            for i = 1, 5 do
                reliable_msg.save("role", 1, "cmd" .. i, {})
            end
            local msgs = reliable_msg.load_pending("role", 1, { after_seq = 3 })
            t.expect(#msgs).to.equal(2)
            t.expect(msgs[1].seq).to.equal(4)
            t.expect(msgs[2].seq).to.equal(5)
        end)

        t.it("历史数据缺少 seq 时不会死循环", function()
            local coll = msg_coll()
            for i = 1, 4 do
                coll.docs[i] = {
                    msg_id = 500 + i,
                    target_type = "role",
                    target_id = 1,
                    cmd = "legacy",
                    status = reliable_msg.STATUS_PENDING,
                }
            end
            local msgs = reliable_msg.load_pending("role", 1, { page_size = 2 })
            t.expect(#msgs).to.equal(2)
            t.expect(#calls_of(coll, "find_many")).to.equal(1)
        end)
    end)

    t.describe("ack 语义", function()
        t.before_each(reset)

        t.it("mark_delivered 置为已投递并记录时间", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            t.expect(reliable_msg.mark_delivered(msg_id)).to.equal(true)
            local doc = reliable_msg.get(msg_id)
            t.expect(doc.status).to.equal(reliable_msg.STATUS_DELIVERED)
            t.expect(doc.delivered_time).to.be_type("number")
        end)

        t.it("ack 查询带 status=pending 条件，重复 ack 返回 false", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            msg_coll().calls = {}
            t.expect(reliable_msg.mark_delivered(msg_id)).to.equal(true)
            local fam = calls_of(msg_coll(), "find_and_modify")[1]
            t.expect(fam.a.query.msg_id).to.equal(msg_id)
            t.expect(fam.a.query.status).to.equal(reliable_msg.STATUS_PENDING)
            t.expect(fam.a.update["$set"].status).to.equal(reliable_msg.STATUS_DELIVERED)

            local ok, reason = reliable_msg.mark_delivered(msg_id)
            t.expect(ok).to.equal(false)
            t.expect(reason).to.equal("already_delivered")
        end)

        t.it("Mongo 驱动返回 BSON null 字节串时不误报 ack 成功", function()
            local coll = msg_coll()
            function coll:find_and_modify()
                return { ok = 1, value = "\0", lastErrorObject = { n = 0 } }
            end
            local ok, reason = reliable_msg.mark_delivered(42)
            t.expect(ok).to.equal(false)
            t.expect(reason).to.equal("already_delivered")
        end)

        t.it("ack 写库失败时返回 false，消息仍为 pending 并会重投", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            env.fam_error = { entity_msg = "mongo down" }
            local ok, err = reliable_msg.mark_delivered(msg_id)
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("mongo down")

            env.fam_error = nil
            local msgs = reliable_msg.load_pending("role", 1)
            t.expect(#msgs).to.equal(1)
            t.expect(msgs[1].msg_id).to.equal(msg_id)
        end)

        t.it("handler 失败不 ack：重投保持原顺序，成功后不再重投（at-least-once）", function()
            for i = 1, 3 do
                reliable_msg.save("role", 1, "cmd" .. i, { i })
            end

            local delivered = {}
            local fail_on = { cmd2 = true }
            -- 模拟 entitymgr/_entity_agent 的投递循环：handler 成功才 ack
            local function deliver_round()
                for _, msg in ipairs(reliable_msg.load_pending("role", 1)) do
                    delivered[#delivered + 1] = msg.cmd
                    if not fail_on[msg.cmd] then
                        reliable_msg.mark_delivered(msg.msg_id)
                    end
                end
            end

            deliver_round()
            t.expect(delivered).to.equal({ "cmd1", "cmd2", "cmd3" })
            -- cmd2 失败未 ack，仍然 pending
            local pending = reliable_msg.load_pending("role", 1)
            t.expect(#pending).to.equal(1)
            t.expect(pending[1].cmd).to.equal("cmd2")

            fail_on = {}
            deliver_round()
            t.expect(delivered).to.equal({ "cmd1", "cmd2", "cmd3", "cmd2" })
            t.expect(#reliable_msg.load_pending("role", 1)).to.equal(0)

            deliver_round()
            t.expect(#delivered).to.equal(4)
        end)

        t.it("重复投递时只有一次 ack 生效，可用于业务去重判断", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            local first = reliable_msg.mark_delivered(msg_id)
            local second = reliable_msg.mark_delivered(msg_id)
            t.expect(first).to.equal(true)
            t.expect(second).to.equal(false)
        end)
    end)

    t.describe("ensure_indexes", function()
        t.before_each(reset)

        t.it("建立 pending 排序索引、msg_id 唯一索引与死信列表索引", function()
            local created = {}
            local coll = msg_coll()
            function coll:create_index(keys, options)
                created[#created + 1] = { keys = keys, options = options }
            end
            reliable_msg.ensure_indexes()
            t.expect(#created).to.equal(3)
            t.expect(created[1].keys.name).to.equal("pending_seq")
            t.expect(created[1].keys[1]).to.equal({ target_type = 1 })
            t.expect(created[1].keys[4]).to.equal({ seq = 1 })
            t.expect(created[2].keys.unique).to.equal(true)
            t.expect(created[3].keys.name).to.equal("dead_time")
            t.expect(created[3].keys[1]).to.equal({ status = 1 })
            t.expect(created[3].keys[2]).to.equal({ dead_time = 1 })
        end)
    end)

    t.describe("投递次数上限", function()
        t.before_each(reset)

        t.it("没有配置时用内置默认值", function()
            t.expect(reliable_msg.max_attempts()).to.equal(reliable_msg.DEFAULT_MAX_ATTEMPTS)
            t.expect(reliable_msg.DEFAULT_MAX_ATTEMPTS).to.equal(5)
        end)

        t.it("节点配置可以覆盖默认值", function()
            config_values.reliable_msg_max_attempts = 2
            t.expect(reliable_msg.max_attempts()).to.equal(2)
        end)

        -- 配错一个数不该把投递整体打挂：那等于把笔误升级成消息积压
        t.it("非法配置回落到默认值而不是报错", function()
            for _, bad in ipairs({ 0, -1, 1.5 }) do
                config_values.reliable_msg_max_attempts = bad
                t.expect(reliable_msg.max_attempts()).to.equal(reliable_msg.DEFAULT_MAX_ATTEMPTS)
            end
        end)
    end)

    t.describe("投递失败计数", function()
        t.before_each(reset)

        t.it("首次失败记为 1 并保存错误与时间", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            t.expect(reliable_msg.record_failure(msg_id, "boom")).to.equal(1)
            local doc = reliable_msg.get(msg_id)
            t.expect(doc.attempts).to.equal(1)
            t.expect(doc.last_error).to.equal("boom")
            t.expect(doc.last_attempt_time).to.be_type("number")
            t.expect(doc.status).to.equal(reliable_msg.STATUS_PENDING)
        end)

        t.it("连续失败逐次累加", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            t.expect(reliable_msg.record_failure(msg_id, "a")).to.equal(1)
            t.expect(reliable_msg.record_failure(msg_id, "b")).to.equal(2)
            t.expect(reliable_msg.get(msg_id).last_error).to.equal("b")
        end)

        -- 错误里是 traceback，不截断的话一条毒消息能把文档撑到 16MB 上限
        t.it("超长错误被截断后才落库", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.record_failure(msg_id, string.rep("x", reliable_msg.MAX_ERROR_LENGTH + 100))
            t.expect(#reliable_msg.get(msg_id).last_error).to.equal(reliable_msg.MAX_ERROR_LENGTH)
        end)

        t.it("已经 ack 的消息不再计数", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.mark_delivered(msg_id)
            local attempts, reason = reliable_msg.record_failure(msg_id, "late")
            t.expect(attempts).to.be_nil()
            t.expect(reason).to.equal("not_matched")
            t.expect(reliable_msg.get(msg_id).attempts).to.be_nil()
        end)

        t.it("写库失败时返回 nil，调用方不能据此判死", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            env.fam_error = { entity_msg = "mongo down" }
            local attempts, reason = reliable_msg.record_failure(msg_id, "boom")
            t.expect(attempts).to.be_nil()
            t.expect(reason).to.equal("mongo down")
        end)
    end)

    t.describe("死信隔离", function()
        t.before_each(reset)

        t.it("判死后消息不再出现在 pending 队列里", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            t.expect(reliable_msg.mark_dead(msg_id, "poison")).to.equal(true)
            local doc = reliable_msg.get(msg_id)
            t.expect(doc.status).to.equal(reliable_msg.STATUS_DEAD)
            t.expect(doc.dead_reason).to.equal("poison")
            t.expect(doc.dead_time).to.be_type("number")
            t.expect(reliable_msg.load_pending("role", 1)).to.equal({})
        end)

        t.it("重复判死是幂等的", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.mark_dead(msg_id, "poison")
            local ok, reason = reliable_msg.mark_dead(msg_id, "again")
            t.expect(ok).to.equal(false)
            t.expect(reason).to.equal("not_pending")
            t.expect(reliable_msg.get(msg_id).dead_reason).to.equal("poison")
        end)

        -- 已经处理成功的消息被判死等于凭空多出一条"失败"记录
        t.it("已经 ack 的消息不能被判死", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.mark_delivered(msg_id)
            t.expect(reliable_msg.mark_dead(msg_id, "poison")).to.equal(false)
            t.expect(reliable_msg.get(msg_id).status).to.equal(reliable_msg.STATUS_DELIVERED)
        end)

        t.it("判死后不能再 ack", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.mark_dead(msg_id, "poison")
            local acked, reason = reliable_msg.mark_delivered(msg_id)
            t.expect(acked).to.equal(false)
            t.expect(reason).to.equal("already_delivered")
            t.expect(reliable_msg.get(msg_id).status).to.equal(reliable_msg.STATUS_DEAD)
        end)

        t.it("超长 reason 同样被截断", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.mark_dead(msg_id, string.rep("y", reliable_msg.MAX_ERROR_LENGTH + 10))
            t.expect(#reliable_msg.get(msg_id).dead_reason).to.equal(reliable_msg.MAX_ERROR_LENGTH)
        end)
    end)

    t.describe("死信重放与丢弃", function()
        t.before_each(reset)

        local function dead_msg(target_id, cmd)
            local msg_id = reliable_msg.save("role", target_id, cmd or "cmd", { 1, 2 })
            reliable_msg.record_failure(msg_id, "boom")
            reliable_msg.mark_dead(msg_id, "boom")
            return msg_id
        end

        t.it("重放把消息放回 pending 并清零计数", function()
            local msg_id = dead_msg(1)
            local doc = reliable_msg.replay(msg_id)
            t.expect(doc.target_type).to.equal("role")
            t.expect(doc.target_id).to.equal(1)
            t.expect(doc.cmd).to.equal("cmd")
            t.expect(doc.status).to.equal(reliable_msg.STATUS_PENDING)
            t.expect(doc.attempts).to.equal(0)
            t.expect(doc.dead_time).to.be_nil()
            t.expect(doc.dead_reason).to.be_nil()
            t.expect(doc.replay_time).to.be_type("number")
            local pending = reliable_msg.load_pending("role", 1)
            t.expect(#pending).to.equal(1)
            t.expect(pending[1].msg_id).to.equal(msg_id)
        end)

        t.it("重放后的消息仍然带着原来的 args", function()
            local msg_id = dead_msg(1)
            reliable_msg.replay(msg_id)
            t.expect(reliable_msg.get(msg_id).args).to.equal({ 1, 2 })
        end)

        t.it("只有死信可以重放", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            local doc, reason = reliable_msg.replay(msg_id)
            t.expect(doc).to.be_nil()
            t.expect(reason).to.equal("not_dead")
        end)

        t.it("重复重放第二次返回 not_dead", function()
            local msg_id = dead_msg(1)
            t.expect(reliable_msg.replay(msg_id)).to.be_type("table")
            local doc, reason = reliable_msg.replay(msg_id)
            t.expect(doc).to.be_nil()
            t.expect(reason).to.equal("not_dead")
        end)

        t.it("丢弃保留文档，只是不再出现在死信列表", function()
            local msg_id = dead_msg(1)
            t.expect(reliable_msg.discard(msg_id, "alice")).to.equal(true)
            local doc = reliable_msg.get(msg_id)
            t.expect(doc.status).to.equal(reliable_msg.STATUS_DISCARDED)
            t.expect(doc.discard_operator).to.equal("alice")
            t.expect(doc.discard_time).to.be_type("number")
            t.expect(reliable_msg.list_dead()).to.equal({})
            t.expect(reliable_msg.load_pending("role", 1)).to.equal({})
        end)

        -- 还在投递中的消息被误删会让生产者以为消息送达了
        t.it("只有死信可以丢弃", function()
            local msg_id = reliable_msg.save("role", 1, "cmd", {})
            local ok, reason = reliable_msg.discard(msg_id)
            t.expect(ok).to.equal(false)
            t.expect(reason).to.equal("not_dead")
            t.expect(reliable_msg.get(msg_id).status).to.equal(reliable_msg.STATUS_PENDING)
        end)

        t.it("丢弃后不能再重放", function()
            local msg_id = dead_msg(1)
            reliable_msg.discard(msg_id)
            local doc, reason = reliable_msg.replay(msg_id)
            t.expect(doc).to.be_nil()
            t.expect(reason).to.equal("not_dead")
        end)
    end)

    t.describe("死信列表", function()
        t.before_each(reset)

        local function dead_msg(target_type, target_id)
            local msg_id = reliable_msg.save(target_type, target_id, "cmd", {})
            reliable_msg.mark_dead(msg_id, "boom")
            return msg_id
        end

        t.it("只返回死信，按入列时间排序", function()
            local dead = dead_msg("role", 1)
            reliable_msg.save("role", 1, "cmd", {})
            local acked = reliable_msg.save("role", 1, "cmd", {})
            reliable_msg.mark_delivered(acked)
            local list = reliable_msg.list_dead()
            t.expect(#list).to.equal(1)
            t.expect(list[1].msg_id).to.equal(dead)
            local calls = calls_of(msg_coll(), "find_many")
            local last = calls[#calls]
            t.expect(last.a.status).to.equal(reliable_msg.STATUS_DEAD)
            t.expect(last.b.sort).to.equal({ dead_time = 1 })
        end)

        t.it("可以按实体类型和 ID 过滤", function()
            dead_msg("role", 1)
            local target = dead_msg("role", 2)
            dead_msg("guild", 2)
            local list = reliable_msg.list_dead({ target_type = "role", target_id = 2 })
            t.expect(#list).to.equal(1)
            t.expect(list[1].msg_id).to.equal(target)
            t.expect(#reliable_msg.list_dead({ target_type = "role" })).to.equal(2)
        end)

        t.it("limit 生效且被上限夹住", function()
            for i = 1, 3 do
                dead_msg("role", i)
            end
            t.expect(#reliable_msg.list_dead({ limit = 2 })).to.equal(2)
            reliable_msg.list_dead({ limit = reliable_msg.MAX_DEAD_PAGE_SIZE + 1000 })
            local calls = calls_of(msg_coll(), "find_many")
            t.expect(calls[#calls].b.limit).to.equal(reliable_msg.MAX_DEAD_PAGE_SIZE)
        end)

        t.it("不传 limit 时用默认条数", function()
            dead_msg("role", 1)
            reliable_msg.list_dead()
            local calls = calls_of(msg_coll(), "find_many")
            t.expect(calls[#calls].b.limit).to.equal(reliable_msg.DEFAULT_DEAD_PAGE_SIZE)
        end)

        t.it("非法 limit 直接报错而不是悄悄拉全表", function()
            t.expect(function()
                reliable_msg.list_dead({ limit = 0 })
            end).to
                .throw("limit must be positive")
        end)
    end)
end)

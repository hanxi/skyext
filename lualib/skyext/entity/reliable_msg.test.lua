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

package.loaded["skyext.mongo_conn"] = fake_mongo
package.loaded["skyext.id_generator"] = fake_idgen

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

        t.it("建立 pending 排序索引与 msg_id 唯一索引", function()
            local created = {}
            local coll = msg_coll()
            function coll:create_index(keys, options)
                created[#created + 1] = { keys = keys, options = options }
            end
            reliable_msg.ensure_indexes()
            t.expect(#created).to.equal(2)
            t.expect(created[1].keys.name).to.equal("pending_seq")
            t.expect(created[1].keys[1]).to.equal({ target_type = 1 })
            t.expect(created[1].keys[4]).to.equal({ seq = 1 })
            t.expect(created[2].keys.unique).to.equal(true)
        end)
    end)
end)

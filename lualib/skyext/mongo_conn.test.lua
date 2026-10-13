local t = require "skytest"
local mongo_conn = require "skyext.mongo_conn"

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
end)

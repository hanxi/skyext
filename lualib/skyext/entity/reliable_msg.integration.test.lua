local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

if os.getenv("SKYTEST_INTEGRATION") ~= "1" then
    return
end

local mongo = require "skynet.db.mongo"
local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local source = fs.join(root, "lualib/skyext/entity/reliable_msg.lua")
local unique = string.format("%d_%d_%d", os.time(), skynet.self(), math.random(1, 1000000000))
local dbname = "skyext_msg_it_" .. unique
local h = { next_id = 10000 }

local function collection(db, name)
    local real = db[name]
    return {
        find_and_modify = function(_, opts)
            return real:findAndModify(opts)
        end,
        safe_insert = function(_, doc)
            return real:safe_insert(doc)
        end,
        find_many = function(_, query, opts)
            local cursor = real:find(query, opts.projection)
            cursor:sort(opts.sort)
            cursor:limit(opts.limit)
            local result = {}
            while cursor:hasNext() do
                result[#result + 1] = cursor:next()
            end
            return result
        end,
        find_one = function(_, query)
            return real:findOne(query)
        end,
        create_index = function(_, opts)
            return real:createIndex(opts)
        end,
    }
end

local function new_reliable_module(db)
    local modules = {
        ["skyext.mongo_conn"] = {
            get_collection = function(_, name)
                return collection(db, name)
            end,
        },
        ["skyext.id_generator"] = {
            newid = function()
                h.next_id = h.next_id - 1
                return h.next_id
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    return assert(loadfile(source, "t", env))()
end

t.describe("MongoDB reliable message integration", function()
    t.before_all(function()
        local host = os.getenv("MONGO_HOST") or "127.0.0.1"
        local port = tonumber(os.getenv("MONGO_PORT")) or 27017
        h.db = mongo.client({ host = host, port = port })[dbname]
        local existing = h.db:runCommand("listCollections", 1)
        t.expect(existing.ok).to.equal(1)
        t.expect(#existing.cursor.firstBatch).to.equal(0)
        h.isolated_db = true
        h.other_db = mongo.client({ host = host, port = port })[dbname]
        h.msg = new_reliable_module(h.db)
        h.other_msg = new_reliable_module(h.other_db)
    end)

    t.after_all(function()
        if h.isolated_db then
            local result = h.db:runCommand("dropDatabase", 1)
            t.expect(result.ok).to.equal(1)
        end
    end)

    t.it("orders persisted pages by seq, atomically allocates concurrently and acks idempotently", function()
        h.msg.ensure_indexes()
        local indexes = h.db:runCommand("listIndexes", "entity_msg")
        t.expect(indexes.ok).to.equal(1)
        local by_name = {}
        for _, index in ipairs(indexes.cursor.firstBatch) do
            by_name[index.name] = index
        end
        t.expect(by_name.pending_seq.key.seq).to.equal(1)
        t.expect(by_name.msg_id.unique).to.equal(true)

        for i = 1, 5 do
            local _, seq = h.msg.save("role", 7, "cmd" .. i, { i })
            t.expect(seq).to.equal(i)
        end
        local ordered = h.msg.load_pending("role", 7, { page_size = 2 })
        t.expect(#ordered).to.equal(5)
        for i, msg in ipairs(ordered) do
            t.expect(msg.seq).to.equal(i)
            t.expect(msg.msg_id).to.equal(10000 - i)
        end
        t.expect(h.msg.mark_delivered(ordered[3].msg_id)).to.equal(true)
        t.expect(h.msg.mark_delivered(ordered[3].msg_id)).to.equal(false)
        t.expect(h.msg.get(ordered[3].msg_id).status).to.equal(h.msg.STATUS_DELIVERED)

        local done = 0
        local failures = {}
        local seen = {}
        for i = 1, 12 do
            skynet.fork(function()
                local producer = i % 2 == 0 and h.other_msg or h.msg
                local ok, msg_id_or_error, seq = pcall(producer.save, "role", 7, "parallel" .. i, { i })
                if ok then
                    seen[seq] = (seen[seq] or 0) + 1
                else
                    failures[#failures + 1] = msg_id_or_error
                end
                done = done + 1
            end)
        end
        while done < 12 do
            skynet.sleep(1)
        end
        t.expect(failures).to.equal({})
        for seq = 6, 17 do
            t.expect(seen[seq]).to.equal(1)
        end

        local pending = h.msg.load_pending("role", 7, { page_size = 3 })
        t.expect(#pending).to.equal(16)
        for i, msg in ipairs(pending) do
            t.expect(msg.seq).to.equal(i < 3 and i or i + 1)
            t.expect(h.msg.mark_delivered(msg.msg_id)).to.equal(true)
        end
        t.expect(#h.msg.load_pending("role", 7, { page_size = 2 })).to.equal(0)
        local _, second_target_seq = h.msg.save("role", 8, "other", {})
        t.expect(second_target_seq).to.equal(1)
    end)
end)

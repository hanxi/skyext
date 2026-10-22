local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local mail_source = fs.join(root, "example/nodes/role/modules/mail/init.lua")
local bag_source = fs.join(root, "example/nodes/role/modules/bag/init.lua")

local DEFAULT_INIT_ITEM = { { res_type = 101, res_id = 10086, res_size = 1 } }

-- 模块只依赖 pairs / 赋值，普通表就能代替 ORM 文档
local function load(source, max_mails, init_item)
    local imports = {
        ["skyext.config"] = {
            get_number = function(key)
                t.expect(key).to.equal("mail_max_count")
                return max_mails
            end,
        },
        -- 策划配置表换成假件，断言的是 bag 怎么用它，不是 example/res 里当前填了什么
        ["skyext.res"] = { param = { InitItem = init_item or DEFAULT_INIT_ITEM } },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    return assert(loadfile(source, "t", env))()
end

local function new_entity(max_mails)
    local entity = { id = 7, modules = {} }
    entity.modules.bag = load(bag_source).new(entity, {})
    entity.modules.mail = load(mail_source, max_mails).new(entity, {})
    return entity
end

local function mail(id, send_time, extra)
    local m = { mail_id = id, title = "t" .. id, send_time = send_time }
    for k, v in pairs(extra or {}) do
        m[k] = v
    end
    return m
end

local function ids(list)
    local out = {}
    for i, m in ipairs(list) do
        out[i] = m.mail_id
    end
    return out
end

t.describe("mail module", function()
    t.it("ignores a redelivered mail with the same id", function()
        local box = new_entity().modules.mail
        t.expect(box:receive(mail(1, 100))).to.equal(true)
        t.expect(box:receive(mail(1, 100, { title = "dup" }))).to.equal(false)
        t.expect(box:list()[1].title).to.equal("t1")
    end)

    t.it("drops the oldest mail when the mailbox is full", function()
        local box = new_entity(2).modules.mail
        box:receive(mail(1, 100))
        box:receive(mail(2, 200))
        box:receive(mail(3, 300))
        t.expect(ids(box:list())).to.equal({ 3, 2 })
    end)

    t.it("lists newest first and breaks send_time ties by id", function()
        local box = new_entity().modules.mail
        box:receive(mail(5, 100))
        box:receive(mail(9, 300))
        box:receive(mail(7, 100))
        t.expect(ids(box:list())).to.equal({ 9, 7, 5 })
    end)

    t.it("hides the zero-valued sender of a system mail", function()
        local box = new_entity().modules.mail
        box:receive(mail(1, 100, { sender = { rid = 0, name = "" } }))
        box:receive(mail(2, 200, { sender = { rid = 42, name = "bob" } }))
        local list = box:list()
        t.expect(list[1].sender).to.equal({ rid = 42, name = "bob" })
        t.expect(list[2].sender).to.be_nil()
    end)

    t.it("moves attachments into the bag and deletes the mail on claim", function()
        local entity = new_entity()
        local box, bag = entity.modules.mail, entity.modules.bag
        box:receive(mail(1, 100, { attach = { { res_type = 101, res_id = 10086, res_size = 4 } } }))
        t.expect(box:claim(1)).to.equal(true)
        -- 新手道具 1 个 + 附件 4 个
        t.expect(bag:count(101, 10086)).to.equal(5)
        t.expect(box:list()).to.equal({})
        t.expect(box:claim(1)).to.equal(false)
    end)
end)

t.describe("bag module", function()
    t.it("grants the starter items once, even after the bag is emptied", function()
        local data = {}
        local bag = load(bag_source).new({ id = 7 }, data)
        t.expect(bag:count(101, 10086)).to.equal(1)
        data.bags = {}
        load(bag_source).new({ id = 7 }, data)
        t.expect(data.bags[101]).to.be_nil()
    end)

    t.it("stacks items and rejects non-positive counts", function()
        local bag = load(bag_source).new({ id = 7 }, {})
        bag:add_item(102, 1, 2)
        bag:add_item(102, 1, 3)
        t.expect(bag:count(102, 1)).to.equal(5)
        t.expect(function()
            bag:add_item(102, 1, 0)
        end).to
            .throw("positive integer")
    end)

    t.it("grants the starter items listed in the res table", function()
        local bag = load(bag_source, nil, {
            { res_type = 101, res_id = 10086, res_size = 1 },
            { res_type = 102, res_id = 20001, res_size = 3 },
        }).new({ id = 7 }, {})
        t.expect(bag:count(101, 10086)).to.equal(1)
        t.expect(bag:count(102, 20001)).to.equal(3)
    end)

    t.it("snapshots the bag as sorted arrays for the protocol", function()
        local bag = load(bag_source).new({ id = 7 }, {})
        bag:add_item(100, 9, 1)
        bag:add_item(100, 3, 2)
        t.expect(bag:snapshot()).to.equal({
            { res_type = 100, res = { { res_id = 3, res_size = 2 }, { res_id = 9, res_size = 1 } } },
            { res_type = 101, res = { { res_id = 10086, res_size = 1 } } },
        })
    end)
end)

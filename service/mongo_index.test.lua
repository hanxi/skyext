local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/mongo_index.lua")

-- 建索引是启动期的一次性动作，失败只记日志不中断，所以这里重点验的是
-- "哪些索引真的发出去了" 和 "出错之后还继不继续"，而不是返回值本身。
local function harness(mongo_config)
    local h = {
        mongo_config = mongo_config,
        clients = {}, -- 每次 mongo.client 收到的 cfg
        created = {}, -- 真正落到 createIndex 的 (db, coll, index)
        logs = {},
        config_reads = 0,
        fail_on = {}, -- coll_name -> 错误信息
        missing = {}, -- coll_name -> true 表示这张表在库里不存在
    }

    local fake_mongo = {
        client = function(cfg)
            h.clients[#h.clients + 1] = cfg
            return setmetatable({}, {
                __index = function(_, dbname)
                    return setmetatable({}, {
                        __index = function(_, coll_name)
                            if h.missing[coll_name] then
                                return nil
                            end
                            return {
                                createIndex = function(_, index)
                                    h.created[#h.created + 1] = { db = dbname, coll = coll_name, index = index }
                                    local err = h.fail_on[coll_name]
                                    if err then
                                        error(err, 0)
                                    end
                                    return true
                                end,
                            }
                        end,
                    })
                end,
            })
        end,
    }

    local function record(level)
        return function(msg, ...)
            h.logs[#h.logs + 1] = { level = level, msg = msg, args = table.pack(...) }
        end
    end

    local imports = {
        skynet = {
            start = function(fn)
                h.start = fn
            end,
        },
        ["skynet.db.mongo"] = fake_mongo,
        ["skyext.config"] = {
            get_table = function(key)
                h.config_reads = h.config_reads + 1
                if key == "mongo_config" then
                    return h.mongo_config
                end
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.CMD = CMD
            end,
        },
        ["skyext.log"] = {
            debug = record("debug"),
            info = record("info"),
            warn = record("warn"),
            error = record("error"),
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    assert(h.start, "mongo_index did not register a start callback")
    h.start()
    assert(h.CMD, "mongo_index did not dispatch CMD")
    return h
end

local function count_logs(h, level)
    local n = 0
    for _, entry in ipairs(h.logs) do
        if entry.level == level then
            n = n + 1
        end
    end
    return n
end

-- 按 "库.表" 聚合实际建出来的索引，避开 pairs 的不确定顺序
local function created_keys(h)
    local keys = {}
    for _, item in ipairs(h.created) do
        keys[#keys + 1] = item.db .. "." .. item.coll
    end
    table.sort(keys)
    return keys
end

t.describe("mongo_index 配置读取时机", function()
    t.it("加载 chunk 时不读配置，只有真正建索引时才读", function()
        -- mongo_config 是 skyext 在 skynet.init 回调里注入的，
        -- 在加载期或启动回调里读都会拿到 nil
        local h = harness({})
        t.expect(h.config_reads).to.equal(0)
        h.CMD.create_indexes()
        t.expect(h.config_reads).to.equal(1)
    end)

    t.it("没有 mongo_config 时直接报错，不返回一个假的成功", function()
        local h = harness(nil)
        t.expect(function()
            h.CMD.create_indexes()
        end).to
            .throw("mongo_config is not configured")
    end)
end)

t.describe("mongo_index 建索引", function()
    t.it("按配置给每张表建出每一条索引，并返回全部成功", function()
        local h = harness({
            game = {
                cfg = { host = "127.0.0.1" },
                collections = {
                    role = { indexes = { { rid = 1 }, { name = 1 } } },
                },
            },
        })
        t.expect(h.CMD.create_indexes()).to.equal(true)
        t.expect(h.clients).to.equal({ { host = "127.0.0.1" } })
        t.expect(#h.created).to.equal(2)
        t.expect(h.created[1].db).to.equal("game")
        t.expect(h.created[1].coll).to.equal("role")
        -- indexes 是数组，顺序必须保留：复合索引的字段先后决定它能不能被用上
        t.expect(h.created[1].index).to.equal({ rid = 1 })
        t.expect(h.created[2].index).to.equal({ name = 1 })
    end)

    t.it("多个库各自用自己的 cfg 建连接", function()
        local h = harness({
            game = { cfg = { host = "a" }, collections = { role = { indexes = { { rid = 1 } } } } },
            global = { cfg = { host = "b" }, collections = { server = { indexes = { { sid = 1 } } } } },
        })
        t.expect(h.CMD.create_indexes()).to.equal(true)
        t.expect(#h.clients).to.equal(2)
        t.expect(created_keys(h)).to.equal({ "game.role", "global.server" })
    end)

    t.it("表没配 indexes 时跳过，不算失败", function()
        local h = harness({
            game = { cfg = {}, collections = { role = {} } },
        })
        t.expect(h.CMD.create_indexes()).to.equal(true)
        t.expect(h.created).to.have_length(0)
    end)
end)

t.describe("mongo_index 失败处理", function()
    t.it("某条索引建失败时记错误日志并继续建后面的", function()
        -- 启动期一条索引建不出来不该让剩下的全部跳过：
        -- 那会让一次偶发失败演变成整库缺索引
        local h = harness({
            game = {
                cfg = {},
                collections = {
                    role = { indexes = { { rid = 1 }, { name = 1 } } },
                },
            },
        })
        h.fail_on.role = "index conflict"
        t.expect(h.CMD.create_indexes()).to.equal(false)
        t.expect(#h.created).to.equal(2)
        t.expect(count_logs(h, "error")).to.equal(2)
        t.expect(count_logs(h, "info")).to.equal(0)
    end)

    t.it("一个库失败不影响另一个库继续建", function()
        local h = harness({
            game = { cfg = {}, collections = { role = { indexes = { { rid = 1 } } } } },
            global = { cfg = {}, collections = { server = { indexes = { { sid = 1 } } } } },
        })
        h.fail_on.role = "boom"
        t.expect(h.CMD.create_indexes()).to.equal(false)
        t.expect(created_keys(h)).to.equal({ "game.role", "global.server" })
        t.expect(count_logs(h, "info")).to.equal(1)
    end)

    t.it("库里没有这张表时记错误并整体返回失败", function()
        local h = harness({
            game = { cfg = {}, collections = { ghost = { indexes = { { a = 1 } } } } },
        })
        h.missing.ghost = true
        t.expect(h.CMD.create_indexes()).to.equal(false)
        t.expect(h.created).to.have_length(0)
        t.expect(h.logs[1].level).to.equal("error")
        t.expect(h.logs[1].msg).to.equal("collection not found")
    end)
end)

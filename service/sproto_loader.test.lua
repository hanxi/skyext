local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/sproto_loader.lua")

-- schema 内容要在一次测试里变来变去（验 checksum 短路），所以用真实临时文件，
-- 只把 sprotoloader / md5 / 事件通道换成替身。
local function sandbox(fn)
    local dir = fs.temporary_dir()
    local ok, err = pcall(fn, dir)
    fs.remove_tree(dir)
    if not ok then
        error(err, 0)
    end
end

local function harness()
    local h = { saves = {}, published = {}, order = {} }

    local imports = {
        skynet = {
            start = function(fn)
                h.start = fn
            end,
        },
        md5 = {
            -- 真 md5 的作用只是"内容变了checksum就变"，替身保持这个性质即可
            sumhexa = function(s)
                return "cs:" .. s
            end,
        },
        sprotoloader = {
            save = function(content, index)
                h.saves[#h.saves + 1] = { content = content, index = index }
                if h.save_error then
                    error(h.save_error, 0)
                end
            end,
        },
        ["skyext.event_channel_api"] = {
            init = function()
                h.order[#h.order + 1] = "channel_init"
            end,
            publish = function(cmd, ...)
                h.published[#h.published + 1] = { cmd = cmd, args = table.pack(...) }
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.order[#h.order + 1] = "gm_register"
                h.gm = cmds
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.order[#h.order + 1] = "dispatch"
                h.CMD = CMD
            end,
        },
        ["skyext.log"] = {
            debug = function() end,
            info = function() end,
            warn = function() end,
            error = function() end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    assert(h.start, "sproto_loader did not register a start callback")
    h.start()
    assert(h.CMD and h.gm, "sproto_loader did not install CMD / GM commands")
    return h
end

local function reload(h)
    return h.gm.reload_sproto_schema.handler()
end

t.describe("sproto_loader 启动", function()
    t.it("先开事件通道再注册 GM 和 CMD", function()
        -- 通道没开就先接客，reload 时 publish 会打在 nil 上
        local h = harness()
        t.expect(h.order).to.equal({ "channel_init", "gm_register", "dispatch" })
    end)

    t.it("GM 指令带 desc 和 handler", function()
        local h = harness()
        t.expect(h.gm.reload_sproto_schema.desc).to.be_type("string")
        t.expect(h.gm.reload_sproto_schema.handler).to.be_type("function")
    end)
end)

t.describe("sproto_loader 首次加载", function()
    t.it("读文件、存进指定 slot、广播路径", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            local ok, proto = h.CMD.load_proto(path, 2)
            t.expect(ok).to.equal(true)
            t.expect(proto.schema_path).to.equal(path)
            t.expect(proto.checksum).to.equal("cs:schema A")
            t.expect(h.saves).to.equal({ { content = "schema A", index = 2 } })
            -- 订阅方靠这条广播知道该重新 host 协议了
            t.expect(h.published[1].cmd).to.equal(path)
        end)
    end)

    t.it("不传 index 时落在 1 号 slot", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            h.CMD.load_proto(path)
            t.expect(h.saves[1].index).to.equal(1)
        end)
    end)

    t.it("不同 slot 之间互不干扰", function()
        sandbox(function(dir)
            local h = harness()
            local a = fs.join(dir, "a.sproto")
            local b = fs.join(dir, "b.sproto")
            fs.write(a, "schema A")
            fs.write(b, "schema B")
            t.expect(h.CMD.load_proto(a, 1)).to.equal(true)
            t.expect(h.CMD.load_proto(b, 2)).to.equal(true)
            t.expect(#h.saves).to.equal(2)
            t.expect(h.saves[2]).to.equal({ content = "schema B", index = 2 })
        end)
    end)
end)

t.describe("sproto_loader 缓存与冲突", function()
    t.it("同一个 slot 重复加载同一路径时直接命中缓存，根本不碰磁盘", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            h.CMD.load_proto(path, 1)
            -- 把文件删掉：真去读就会失败，能成功说明走的是缓存
            fs.remove_tree(path)
            local ok, proto = h.CMD.load_proto(path, 1)
            t.expect(ok).to.equal(true)
            t.expect(proto.checksum).to.equal("cs:schema A")
            t.expect(#h.saves).to.equal(1)
            t.expect(#h.published).to.equal(1)
        end)
    end)

    t.it("同一个 slot 被换成另一个路径时报冲突，且不覆盖已加载的", function()
        sandbox(function(dir)
            local h = harness()
            local a = fs.join(dir, "a.sproto")
            local b = fs.join(dir, "b.sproto")
            fs.write(a, "schema A")
            fs.write(b, "schema B")
            h.CMD.load_proto(a, 1)
            local ok, err = h.CMD.load_proto(b, 1)
            t.expect(ok).to.equal(false)
            -- 两份不同的 schema 抢同一个 index，后来者悄悄覆盖会让已连客户端
            -- 的协议号整体错位，必须拒绝
            t.expect(err).to.contain("proto index conflict")
            t.expect(err).to.contain(a)
            t.expect(err).to.contain(b)
            t.expect(#h.saves).to.equal(1)

            fs.remove_tree(a)
            local ok2, proto = h.CMD.load_proto(a, 1)
            t.expect(ok2).to.equal(true)
            t.expect(proto.checksum).to.equal("cs:schema A")
        end)
    end)
end)

t.describe("sproto_loader 加载失败", function()
    t.it("文件读不到时返回错误，slot 保持为空以便重试", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "missing.sproto")
            local ok, err = h.CMD.load_proto(path, 1)
            t.expect(ok).to.equal(false)
            t.expect(err).to.be_type("string")
            t.expect(h.saves).to.have_length(0)
            t.expect(h.published).to.have_length(0)

            fs.write(path, "schema A")
            t.expect(h.CMD.load_proto(path, 1)).to.equal(true)
            t.expect(#h.saves).to.equal(1)
        end)
    end)

    t.it("sprotoloader.save 失败时不记 checksum、不广播，修好后还能重来", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            h.save_error = "bad schema"
            local ok, err = h.CMD.load_proto(path, 1)
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("bad schema")
            -- 半成功最危险：记下 checksum 后下次会被当成"已加载"跳过，
            -- 于是这个 slot 永远是空的却没人再试
            t.expect(h.published).to.have_length(0)

            h.save_error = nil
            local ok2, proto = h.CMD.load_proto(path, 1)
            t.expect(ok2).to.equal(true)
            t.expect(proto.checksum).to.equal("cs:schema A")
            t.expect(#h.published).to.equal(1)
        end)
    end)
end)

t.describe("sproto_loader GM 重载", function()
    t.it("没加载过任何 schema 时重载是空操作", function()
        local h = harness()
        t.expect(reload(h)).to.equal(true)
        t.expect(h.saves).to.have_length(0)
    end)

    t.it("内容没变时跳过 save 和广播", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            h.CMD.load_proto(path, 1)
            t.expect(reload(h)).to.equal(true)
            -- 每次 reload 都重新 save + 广播会让所有订阅方白白重建一次协议
            t.expect(#h.saves).to.equal(1)
            t.expect(#h.published).to.equal(1)
        end)
    end)

    t.it("内容变了就重新 save、更新 checksum 并再广播一次", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            local _, proto = h.CMD.load_proto(path, 1)
            fs.write(path, "schema A2")
            t.expect(reload(h)).to.equal(true)
            t.expect(#h.saves).to.equal(2)
            t.expect(h.saves[2]).to.equal({ content = "schema A2", index = 1 })
            t.expect(proto.checksum).to.equal("cs:schema A2")
            t.expect(#h.published).to.equal(2)
        end)
    end)

    t.it("重载覆盖所有已加载的 slot", function()
        sandbox(function(dir)
            local h = harness()
            local a = fs.join(dir, "a.sproto")
            local b = fs.join(dir, "b.sproto")
            fs.write(a, "schema A")
            fs.write(b, "schema B")
            h.CMD.load_proto(a, 1)
            h.CMD.load_proto(b, 2)
            fs.write(a, "schema A2")
            fs.write(b, "schema B2")
            t.expect(reload(h)).to.equal(true)
            t.expect(#h.saves).to.equal(4)
        end)
    end)

    t.it("任意一个 slot 重载失败就整体报失败", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            h.CMD.load_proto(path, 1)
            fs.write(path, "schema A2")
            h.save_error = "bad schema"
            local ok, err = reload(h)
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("bad schema")
        end)
    end)

    t.it("schema 文件被删掉时重载失败而不是抛异常", function()
        sandbox(function(dir)
            local h = harness()
            local path = fs.join(dir, "a.sproto")
            fs.write(path, "schema A")
            h.CMD.load_proto(path, 1)
            fs.remove_tree(path)
            local ok, err = reload(h)
            t.expect(ok).to.equal(false)
            t.expect(err).to.be_type("string")
        end)
    end)
end)

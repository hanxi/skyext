local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/res.lua")

local SEP = package.config:sub(1, 1)
local SERVICE_ADDR = 7
local SELF = 999

-- files: { ["res"] = { ["item.lua"] = "return {1}", ["sub"] = { dir = true } }, ... }
-- 目录不存在就不要在表里给键：mock 的 lfs.dir 会像真的 lfs 一样报错
local function harness(opts)
    opts = opts or {}
    local h = {
        files = opts.files or { res = {}, ["res" .. SEP .. "lazy"] = {} },
        shared = {},
        loads = {},
        queries = {},
        published = {},
        sends = {},
    }

    local function entry_of(path)
        for dir, entries in pairs(h.files) do
            local prefix = dir .. SEP
            if path:sub(1, #prefix) == prefix then
                local e = entries[path:sub(#prefix + 1)]
                if e then
                    return e
                end
            end
        end
    end

    local fake_lfs = {}
    function fake_lfs.dir(path)
        local entries = h.files[path]
        if not entries then
            error("cannot open " .. path)
        end
        local names = { ".", ".." }
        for name in pairs(entries) do
            names[#names + 1] = name
        end
        table.sort(names)
        local i = 0
        return function()
            i = i + 1
            return names[i]
        end
    end
    function fake_lfs.attributes(path)
        local e = entry_of(path)
        if not e then
            return nil
        end
        return { mode = type(e) == "table" and e.dir and "directory" or "file" }
    end

    local fake_io = {}
    function fake_io.readfile(path)
        local e = entry_of(path)
        return type(e) == "string" and e or nil
    end

    local fake_sharetable = {}
    function fake_sharetable.loadstring(name, content)
        h.loads[#h.loads + 1] = { name = name, content = content }
        -- 每次 loadstring 产出一个新的表对象，query 才能分辨拿到的是不是新版本
        h.shared[name] = { name = name, content = content }
    end
    function fake_sharetable.query(name)
        h.queries[#h.queries + 1] = name
        return h.shared[name]
    end

    local fake_event = {}
    function fake_event.init() end
    function fake_event.publish(name, data)
        h.published[#h.published + 1] = { name = name, data = data }
    end
    function fake_event.subscribe(addr, name, cb)
        h.subscribe_addr = addr
        h.subscribe_event = name
        h.on_reload = cb
    end

    local fake_skynet = {}
    function fake_skynet.init(fn)
        h.client_init = fn
    end
    function fake_skynet.self()
        return SELF
    end
    function fake_skynet.send(addr, proto, cmd, src)
        h.sends[#h.sends + 1] = { addr = addr, cmd = cmd, src = src }
    end
    function fake_skynet.call(addr, _, cmd, src)
        t.expect(addr).to.equal(SERVICE_ADDR)
        return h.CMD[cmd](src)
    end
    function fake_skynet.start(fn)
        h.service_start = fn
    end

    local fake_service = {}
    -- 真实的 service.new 会把服务拉起来再返回地址，这里按同样的顺序跑完服务侧启动
    function fake_service.new(name, fn)
        h.service_name = name
        fn()
        assert(h.service_start, "service did not call skynet.start")()
        return SERVICE_ADDR
    end

    local noop = function() end
    local imports = {
        skynet = fake_skynet,
        lfs = fake_lfs,
        md5 = {
            sumhexa = function(s)
                return "md5(" .. s .. ")"
            end,
        },
        ["skynet.service"] = fake_service,
        ["skynet.sharetable"] = fake_sharetable,
        ["skyext.util.io"] = fake_io,
        ["skyext.event_channel_api"] = fake_event,
        ["skyext.log"] = { debug = noop, info = noop, warn = noop, error = noop },
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.CMD = CMD
            end,
        },
        ["skyext.gm_api"] = {
            register = function(GM_CMD)
                h.GM_CMD = GM_CMD
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                return (opts.config or {})[key]
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.res = assert(loadfile(source, "t", env))()
    if not opts.defer then
        h.client_init()
    end
    function h.reload(params)
        return h.GM_CMD.reload_res.handler(params or {})
    end
    return h
end

local function files(preload, lazy)
    return { res = preload or {}, ["res" .. SEP .. "lazy"] = lazy or {} }
end

local function names_loaded(h)
    local seen = {}
    for _, load in ipairs(h.loads) do
        seen[load.name] = true
    end
    return seen
end

t.describe("res 服务启动加载", function()
    t.it("只收 .lua 文件，目录和其他后缀一律跳过", function()
        local h = harness({
            files = files({
                ["item.lua"] = "return {1}",
                ["README.md"] = "doc",
                ["item"] = { dir = true },
                ["skill.lua.bak"] = "stale",
            }),
        })
        t.expect(names_loaded(h)).to.equal({ item = true })
    end)

    t.it("预加载目录和懒加载目录分开记账", function()
        local h = harness({
            files = files({ ["item.lua"] = "return {1}" }, { ["skill.lua"] = "return {2}" }),
        })
        local preload, lazy = h.CMD.open(SELF)
        t.expect(preload).to.equal({ item = true })
        t.expect(lazy).to.equal({ skill = true })
    end)

    t.it("资源名取的是去掉 .lua 的文件名，不含目录", function()
        local h = harness({ files = files({ ["item_table.lua"] = "return {1}" }) })
        t.expect(h.loads[1].name).to.equal("item_table")
        t.expect(h.loads[1].content).to.equal("return {1}")
    end)

    t.it("同名资源同时出现在两个目录时启动直接失败", function()
        -- 两份同名资源只会有一份生效，静默覆盖比起不来更难查
        t.expect(function()
            harness({ files = files({ ["item.lua"] = "a" }, { ["item.lua"] = "b" }) })
        end).to
            .throw("res file already loaded")
    end)

    t.it("自定义 res_path 和 res_lazy_path 生效", function()
        local h = harness({
            config = { res_path = "game/res", res_lazy_path = "game/lazy" },
            files = {
                ["game/res"] = { ["item.lua"] = "return {1}" },
                ["game/lazy"] = { ["skill.lua"] = "return {2}" },
            },
        })
        t.expect(names_loaded(h)).to.equal({ item = true, skill = true })
    end)
end)

t.describe("res 服务引用计数", function()
    t.it("open 登记调用方并返回两张资源名表", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        local preload, lazy = h.CMD.open(SELF)
        t.expect(preload).to.equal({ item = true })
        t.expect(lazy).to.equal({})
        -- 重复 open 返回的必须是同一张表：客户端侧靠它感知后来新增的懒加载资源
        local again = h.CMD.open(SELF)
        t.expect(again).to.equal(preload)
    end)

    t.it("close 未登记过的调用方不报错", function()
        local h = harness()
        t.expect(function()
            h.CMD.close(12345)
        end).to_not
            .throw()
    end)
end)

t.describe("res 重载", function()
    t.it("内容没变时不重新加载，也不广播事件", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        local loads = #h.loads
        local ok, msg = h.reload()
        t.expect(ok).to.equal(true)
        t.expect(msg).to.contain("no diff")
        t.expect(h.loads).to.have_length(loads)
        t.expect(h.published).to.have_length(0)
    end)

    t.it("只重载内容真的变了的那些文件", function()
        local h = harness({
            files = files({ ["item.lua"] = "return {1}", ["skill.lua"] = "return {2}" }),
        })
        h.loads = {}
        h.files.res["item.lua"] = "return {11}"
        local ok = h.reload()
        t.expect(ok).to.equal(true)
        t.expect(names_loaded(h)).to.equal({ item = true })
        t.expect(h.loads[1].content).to.equal("return {11}")
    end)

    t.it("重载成功后广播变更的资源名，供各服务刷新本地引用", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        h.files.res["item.lua"] = "return {11}"
        h.reload()
        t.expect(h.published).to.have_length(1)
        t.expect(h.published[1].name).to.equal("res_reload")
        t.expect(h.published[1].data).to.equal({ item = true })
    end)

    t.it("带 filepaths 时按路径末段取资源名，只碰指定的文件", function()
        local h = harness({
            files = files({ ["item.lua"] = "return {1}" }, { ["skill.lua"] = "return {2}" }),
        })
        h.loads = {}
        h.files.res["item.lua"] = "return {11}"
        h.files["res" .. SEP .. "lazy"]["skill.lua"] = "return {22}"
        h.reload({ filepaths = { "res" .. SEP .. "lazy" .. SEP .. "skill.lua" } })
        t.expect(names_loaded(h)).to.equal({ skill = true })
    end)

    t.it("重载后再改一次还能继续重载：哈希跟着更新", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        h.files.res["item.lua"] = "return {11}"
        h.reload()
        -- 哈希没更新的话第二轮会把同样的内容再加载一遍
        local _, msg = h.reload()
        t.expect(msg).to.contain("no diff")
        h.files.res["item.lua"] = "return {111}"
        local _, msg2 = h.reload()
        t.expect(msg2).to.contain("success")
    end)

    t.it("两个目录都空时直接返回，不广播事件", function()
        local h = harness()
        local ok, msg = h.reload()
        t.expect(ok).to.equal(true)
        t.expect(msg).to.contain("no res file")
        t.expect(h.published).to.have_length(0)
    end)
end)

t.describe("res 客户端访问", function()
    t.it("启动时把预加载资源全部取到本地，懒加载的一个都不取", function()
        local h = harness({
            files = files({ ["item.lua"] = "return {1}" }, { ["skill.lua"] = "return {2}" }),
        })
        t.expect(h.queries).to.equal({ "item" })
        t.expect(h.subscribe_addr).to.equal(SERVICE_ADDR)
        t.expect(h.subscribe_event).to.equal("res_reload")
    end)

    t.it("懒加载资源第一次访问才去取，之后走本地缓存", function()
        local h = harness({ files = files({}, { ["skill.lua"] = "return {2}" }) })
        t.expect(h.queries).to.have_length(0)
        local first = h.res.skill
        t.expect(first).to.exist()
        t.expect(h.queries).to.equal({ "skill" })
        t.expect(h.res.skill).to.equal(first)
        t.expect(h.queries).to.have_length(1)
    end)

    t.it("没登记过的资源名返回 nil，不去查 sharetable", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        h.queries = {}
        t.expect(h.res.not_a_res).to.be_nil()
        t.expect(h.queries).to.have_length(0)
    end)

    t.it("收到重载事件后本地拿到的是新版本", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        local before = h.res.item
        h.files.res["item.lua"] = "return {11}"
        h.reload()
        h.on_reload(h.published[1].data)
        local after = h.res.item
        t.expect(after).to_not.equal(before)
        t.expect(after.content).to.equal("return {11}")
    end)

    t.it("重载带来的新资源被登记成懒加载，之后能正常访问", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        h.files.res["newres.lua"] = "return {9}"
        h.reload()
        h.on_reload(h.published[1].data)
        -- 新增资源在启动时不存在，既不在 preload 也不在 lazy，必须补登记
        t.expect(h.res.newres).to.exist()
        t.expect(h.res.newres.content).to.equal("return {9}")
    end)

    t.it("重载事件里没加载过的预加载资源不会被重新取一遍", function()
        local h = harness({ files = files({ ["item.lua"] = "return {1}" }) })
        h.queries = {}
        -- 本地从没取过 ghost，重载通知也不该凭空把它拉进来
        h.on_reload({ ghost = true })
        t.expect(h.queries).to.have_length(0)
    end)
end)

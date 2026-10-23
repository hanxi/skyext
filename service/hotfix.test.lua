local t = require "skytest"
local skynet = require "skynet"
local cjson = require "cjson"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local source = fs.join(root, "service/hotfix.lua")

local BASE_CONF = "desc = '测试补丁', checksum = {}, gitsha_base = 'base1', "
    .. "gitsha_update = 'upd1', time = '2026-01-20 10:00:00',"

-- 拼一个必填字段齐全的 hotfix.conf.lua，body 里放本次要测的开关
local function conf(body)
    return "return {" .. BASE_CONF .. (body or "") .. "}"
end

local function patcher(targets, body)
    local names = {}
    for i, name in ipairs(targets) do
        names[i] = string.format("%q", name)
    end
    return string.format(
        "%s\nreturn { targets = { %s }, run = function() return 'ok' end }",
        body or "",
        table.concat(names, ", ")
    )
end

local function harness(opts)
    opts = opts or {}
    local h = {
        root = fs.temporary_dir(),
        gm_calls = {},
        gm_results = {},
        injects = {},
        logs = {},
        forks = {},
        now = 0,
        time = 1700000000,
    }

    h.write = function(relpath, content)
        fs.write(fs.join(h.root, relpath), content)
    end
    h.history_file = function()
        return fs.join(h.root, "hotfix_history.jsonl")
    end

    h.env = { root = h.root, nodename = "node1" }
    for k, v in pairs(opts.env or {}) do
        h.env[k] = v
    end
    if opts.before then
        opts.before(h)
    end

    local fake_skynet = setmetatable({
        start = function(f)
            f()
        end,
        getenv = function(name)
            return h.env[name]
        end,
        -- 与 skynet 的 QUERY 一致：只有带前导点的本地名才查得到
        localname = function(name)
            if name:sub(1, 1) ~= "." then
                return nil
            end
            return h.names and h.names[name]
        end,
        now = function()
            return h.now
        end,
        sleep = function(ticks)
            h.now = h.now + ticks
        end,
        wakeup = function() end,
        -- 默认同步执行：call_with_timeout 在 fork 里完成调用，done 立刻为真，走不到等待循环。
        -- 要测超时就把 defer_fork 打开，让 fork 的函数排队不执行。
        fork = function(fn)
            if h.defer_fork then
                h.forks[#h.forks + 1] = fn
            else
                fn()
            end
        end,
        call = function(addr, protocol, cmd, ...)
            local src, filename = ...
            h.injects[#h.injects + 1] = { addr = addr, cmd = cmd, filename = filename, source = src }
            if h.inject_error then
                error(h.inject_error)
            end
            -- 与 skynet debug RUN 一致：回 (ok, output)，补丁抛错时 ok 为 false、错误在 output 里
            if h.inject_failed then
                return false, h.inject_failed
            end
            return true, h.inject_output or "patched"
        end,
    }, { __index = skynet })

    local function record_log(level)
        return function(msg, ...)
            h.logs[#h.logs + 1] = { level = level, msg = msg, args = table.pack(...) }
        end
    end

    local imports = {
        skynet = fake_skynet,
        cjson = cjson,
        ["skyext.log"] = {
            info = record_log("info"),
            warn = record_log("warn"),
            error = record_log("error"),
        },
        ["skyext.hotfix_checksum"] = {
            verify = function(config, dir, root_dir)
                h.checksum_args = { config = config, dir = dir, root = root_dir }
                if h.checksum_err then
                    return false, h.checksum_err
                end
                return true
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.cmds = cmds
            end,
            execute_command = function(cmd, params)
                h.gm_calls[#h.gm_calls + 1] = cmd
                if h.on_gm then
                    h.on_gm(cmd, params)
                end
                return h.gm_results[cmd] or {}
            end,
        },
        ["skyext.entity.types"] = {
            get = function(type_name)
                local cfg = h.entity_types and h.entity_types[type_name]
                if not cfg then
                    error("unknown entity type: " .. tostring(type_name))
                end
                return cfg
            end,
            format_agent_service_name = require("skyext.entity.types").format_agent_service_name,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmds)
                h.CMD = cmds
            end,
        },
    }

    local fake_os = setmetatable({
        time = function()
            return h.time
        end,
        date = function(_, when)
            return "T" .. tostring(when)
        end,
    }, { __index = os })

    local env = setmetatable({
        os = fake_os,
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })

    assert(loadfile(source, "t", env))()
    assert(h.cmds, "hotfix did not register GM commands")

    h.run = function(params)
        return h.cmds.hotfix.handler(params)
    end
    h.history = function(params)
        return h.cmds.hotfix_history.handler(params or {})
    end
    return h
end

-- 每个用例一套干净的临时 root，跑完连同历史文件一起删掉
local function with(opts, fn)
    if fn == nil then
        fn, opts = opts, nil
    end
    local h = harness(opts)
    local ok, err = pcall(fn, h)
    fs.remove_tree(h.root)
    if not ok then
        error(err, 0)
    end
end

local function step_named(result, name)
    for _, step in ipairs(result.steps or {}) do
        if step.name == name then
            return step
        end
    end
end

local function step_names(result)
    local names = {}
    for i, step in ipairs(result.steps or {}) do
        names[i] = step.name
    end
    return names
end

t.describe("hotfix 启动注册", function()
    t.it("注册 hotfix 与 hotfix_history 两个 GM 命令并挂上 CMD 分发", function()
        with(function(h)
            t.expect(h.cmds.hotfix.handler).to.be_type("function")
            t.expect(h.cmds.hotfix_history.handler).to.be_type("function")
            t.expect(h.CMD).to.exist()
        end)
    end)
end)

t.describe("hotfix 参数校验", function()
    t.it("不传 hotfix_dir 直接拒绝", function()
        with(function(h)
            local ok, err = h.run({})
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("Missing required parameter: hotfix_dir")
        end)
    end)

    t.it("带 .. 的路径一律拒绝，GM 通道不能被用来读工程外的文件", function()
        with(function(h)
            for _, dir in ipairs({ "../etc", "a/../../b", "..", "pkg/.." }) do
                local ok, err = h.run({ hotfix_dir = dir, confirm = true })
                t.expect(ok).to.equal(false)
                t.expect(err).to.equal("Invalid hotfix_dir: must be a relative path without '..'")
            end
            -- 既然参数就被挡住了，就不该留下任何执行痕迹
            t.expect(h.gm_calls).to.have_length(0)
            local _, list = h.history()
            t.expect(list).to.have_length(0)
        end)
    end)

    t.it("绝对路径和盘符路径同样拒绝", function()
        with(function(h)
            local ok, err = h.run({ hotfix_dir = "/etc/passwd", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("Invalid hotfix_dir: must be a relative path without '..'")

            ok, err = h.run({ hotfix_dir = "C:/windows", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("Invalid hotfix_dir: must be a relative path without '..'")
        end)
    end)

    t.it("run 模式不带 confirm 时什么都不做", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            local ok, err = h.run({ hotfix_dir = "pkg" })
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal("高危操作，请传 confirm=true 确认执行")
            t.expect(h.gm_calls).to.have_length(0)
            t.expect(fs.mode(h.history_file())).to.be_nil()
        end)
    end)

    t.it("confirm 传字符串 true 也认", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf())
            local ok = h.run({ hotfix_dir = "pkg", confirm = "true" })
            t.expect(ok).to.equal(true)
        end)
    end)
end)

t.describe("hotfix 配置加载", function()
    t.it("配置文件不存在时停在 load_config 并给出排查指引", function()
        with(function(h)
            local ok, result = h.run({ hotfix_dir = "missing", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_names(result)).to.equal({ "load_config" })
            t.expect(result.guidance).to.match("hotfix.conf.lua")
        end)
    end)

    t.it("配置语法错误时报 load 失败而不是崩在服务里", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", "return { this is not lua")
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "load_config").result).to.match("Failed to load config")
        end)
    end)

    t.it("配置执行期抛错时被捕获", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", "error('boom')")
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "load_config").result).to.match("Failed to execute config")
        end)
    end)

    t.it("配置不返回 table 时拒绝", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", "return 42")
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "load_config").result).to.equal("Config must return a table")
        end)
    end)

    t.it("缺任一必填字段都要点名说缺哪个", function()
        local fields = { "desc", "checksum", "gitsha_base", "gitsha_update", "time" }
        for _, missing in ipairs(fields) do
            with(function(h)
                local parts = {}
                for _, field in ipairs(fields) do
                    if field ~= missing then
                        parts[#parts + 1] = string.format("%s = %q", field, "x")
                    end
                end
                h.write("pkg/hotfix.conf.lua", "return {" .. table.concat(parts, ",") .. "}")
                local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
                t.expect(ok).to.equal(false)
                t.expect(step_named(result, "load_config").result).to.equal("Missing required field: " .. missing)
            end)
        end
    end)

    t.it("配置里的全局泄漏不会污染服务环境", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", "leaked = 1\n" .. conf())
            local ok = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(_G.leaked).to.be_nil()
        end)
    end)
end)

t.describe("hotfix checksum 校验", function()
    t.it("校验失败就停在 verify_checksum，一个 GM 命令都不发", function()
        with(function(h)
            h.checksum_err = "file changed: a.lua"
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_names(result)).to.equal({ "load_config", "verify_checksum" })
            t.expect(step_named(result, "verify_checksum").result).to.equal("file changed: a.lua")
            -- 校验没过还往下走等于把未经核对的代码注进线上
            t.expect(h.gm_calls).to.have_length(0)
            t.expect(result.guidance).to.match("refresh")
        end)
    end)

    t.it("校验拿到的是解析后的配置和工程根目录", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf())
            h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(h.checksum_args.dir).to.equal("pkg")
            t.expect(h.checksum_args.root).to.equal(h.root)
            t.expect(h.checksum_args.config.gitsha_base).to.equal("base1")
        end)
    end)
end)

t.describe("hotfix 步骤编排", function()
    t.it("按配置开关依次执行四个重载步骤", function()
        with(function(h)
            h.write(
                "pkg/hotfix.conf.lua",
                conf("clearcache = true, reload_res = true, reload_sproto = true, reload_orm_schema = true,")
            )
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(h.gm_calls).to.equal({ "clearcache", "reload_res", "reload_sproto_schema", "reload_orm_schema" })
            t.expect(step_names(result)).to.equal({
                "load_config",
                "verify_checksum",
                "clear_cache",
                "reload_res",
                "reload_sproto",
                "reload_orm_schema",
            })
            t.expect(result.message).to.equal("Hotfix completed successfully")
        end)
    end)

    t.it("开关没打开的步骤完全不执行", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("reload_res = true,"))
            h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(h.gm_calls).to.equal({ "reload_res" })
        end)
    end)

    t.it("默认 fail_fast：某一步失败后面的步骤不再执行", function()
        with(function(h)
            h.gm_results.reload_res = { code = 1, error = "sharetable busy" }
            h.write("pkg/hotfix.conf.lua", conf("reload_res = true, reload_sproto = true,"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(h.gm_calls).to.equal({ "reload_res" })
            t.expect(step_named(result, "reload_res").result).to.match("sharetable busy")
            t.expect(step_named(result, "reload_sproto")).to.be_nil()
            t.expect(result.guidance).to.match("sharetable")
        end)
    end)

    t.it("fail_fast=false 时失败步骤不挡住后面的步骤，但整体仍判失败", function()
        with(function(h)
            h.gm_results.reload_res = { code = 1, error = "boom" }
            h.write("pkg/hotfix.conf.lua", conf("fail_fast = false, reload_res = true, reload_sproto = true,"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(h.gm_calls).to.equal({ "reload_res", "reload_sproto_schema" })
            t.expect(step_named(result, "reload_sproto").success).to.equal(true)
            t.expect(result.message).to.equal("Hotfix completed with errors")
        end)
    end)

    t.it("GM 返回 code=0 当成成功，不是只看有没有 error 字段", function()
        with(function(h)
            h.gm_results.clearcache = { code = 0 }
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            local ok = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
        end)
    end)

    t.it("部署版本与热更基线不一致时给出警告但照常执行", function()
        with({ env = { build_version = "othersha" } }, function(h)
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(result.version_warning).to.match("othersha")
            t.expect(result.version_warning).to.match("base1")
            t.expect(h.gm_calls).to.equal({ "clearcache" })
        end)
    end)

    t.it("部署版本与基线一致时没有警告", function()
        with({ env = { build_version = "base1" } }, function(h)
            h.write("pkg/hotfix.conf.lua", conf())
            local _, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(result.version_warning).to.be_nil()
        end)
    end)
end)

t.describe("hotfix patcher 解析", function()
    t.it("patcher 顶层访问全局变量会被沙箱拦下", function()
        with(function(h)
            h.names = { [".agent"] = 0x10 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }, "local x = skynet"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            local results = step_named(result, "inject_code").result
            t.expect(results[1].error).to.match("cannot access global: skynet")
            t.expect(h.injects).to.have_length(0)
        end)
    end)

    t.it("patcher 可以用白名单里的标准库", function()
        with(function(h)
            h.names = { [".agent"] = 0x10 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }, "local s = string.format('%d', 1) .. table.concat({})"))
            local ok = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
        end)
    end)

    t.it("patcher 文件缺失时报读取失败", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'nope.lua' },"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result[1].error).to.match("Failed to read patcher file")
        end)
    end)

    t.it("patcher 不返回 table 或缺 targets 都要拒绝", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("fail_fast = false, code_files = { 'a.lua', 'b.lua' },"))
            h.write("pkg/a.lua", "return 1")
            h.write("pkg/b.lua", "return { run = function() end }")
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            local results = step_named(result, "inject_code").result
            t.expect(results[1].error).to.equal("Patcher must return a table")
            t.expect(results[2].error).to.equal("Patcher must have targets field (array)")
        end)
    end)
end)

t.describe("hotfix 目标服务定位", function()
    t.it("省略前导点的本地名补上点再查", function()
        with(function(h)
            h.names = { [".agent"] = 0x20 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ "agent" }))
            local ok = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(h.injects[1].addr).to.equal(0x20)
        end)
    end)

    t.it("服务找不到时记失败并给出 inject_code 指引", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".ghost" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            local entry = step_named(result, "inject_code").result[1]
            t.expect(entry.service).to.equal(".ghost")
            t.expect(entry.error).to.equal("Service not found")
            t.expect(result.guidance).to.match("禁止直接重跑整包")
        end)
    end)

    t.it("通配符只允许出现在末尾且只能有一个", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("fail_fast = false, code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".a*b", ".a*b*" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            local results = step_named(result, "inject_code").result
            t.expect(results[1].error).to.equal("Wildcard (*) only allowed at end of service name")
            t.expect(results[2].error).to.equal("Wildcard (*) only allowed at end of service name")
            t.expect(h.injects).to.have_length(0)
        end)
    end)

    t.it("通配符展开成该实体类型配置的全部 agent", function()
        with(function(h)
            h.entity_types = { role = { agent_count = 3 } }
            h.names = {
                [".entity_agent:role:1"] = 0x31,
                [".entity_agent:role:2"] = 0x32,
                [".entity_agent:role:3"] = 0x33,
                -- 别的类型、超出 agent_count 的同前缀名字都不该被打上补丁
                [".entity_agent:rank:1"] = 0x41,
                [".entity_agent:role:4"] = 0x34,
            }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".entity_agent:role:*" }))
            local ok = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(h.injects).to.have_length(3)
            t.expect(h.injects[1].addr).to.equal(0x31)
            t.expect(h.injects[2].addr).to.equal(0x32)
            t.expect(h.injects[3].addr).to.equal(0x33)
        end)
    end)

    t.it("实体类型没配 agent_count 时按 1 个展开，与 entity_agentmgr 的缺省一致", function()
        with(function(h)
            h.entity_types = { rank = {} }
            h.names = { [".entity_agent:rank:1"] = 0x41, [".entity_agent:rank:2"] = 0x42 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".entity_agent:rank:*" }))
            t.expect(h.run({ hotfix_dir = "pkg", confirm = true })).to.equal(true)
            t.expect(h.injects).to.have_length(1)
            t.expect(h.injects[1].addr).to.equal(0x41)
        end)
    end)

    t.it("缺了任何一个 agent 就整条失败，一个都不注入", function()
        with(function(h)
            h.entity_types = { role = { agent_count = 3 } }
            h.names = { [".entity_agent:role:1"] = 0x31, [".entity_agent:role:3"] = 0x33 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".entity_agent:role:*" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            -- 只打一部分 agent 会让同类型实体跑着两套代码，比不打更糟
            t.expect(h.injects).to.have_length(0)
            local entry = step_named(result, "inject_code").result[1]
            t.expect(entry.error).to.equal("Entity agents not found: .entity_agent:role:2")
        end)
    end)

    t.it("本节点不承载该类型（一个 agent 都没有）时算服务找不到", function()
        with(function(h)
            h.entity_types = { role = { agent_count = 2 } }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".entity_agent:role:*" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result[1].error).to.equal("Service not found")
        end)
    end)

    t.it("实体 agent 以外的通配一律拒绝", function()
        with(function(h)
            h.names = { [".agent1"] = 0x51, [".launcher"] = 0x52 }
            h.write("pkg/hotfix.conf.lua", conf("fail_fast = false, code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent*", ".entity_agent:*", ".l*" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            local results = step_named(result, "inject_code").result
            for i = 1, 3 do
                t.expect(results[i].error).to.equal("Wildcard (*) only supported as .entity_agent:<type>:*")
            end
            t.expect(h.injects).to.have_length(0)
        end)
    end)

    t.it("未知实体类型的通配报类型错误", function()
        with(function(h)
            h.entity_types = { role = { agent_count = 1 } }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".entity_agent:guild:*" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result[1].error).to.equal("Unknown entity type: guild")
        end)
    end)
end)

t.describe("hotfix 代码注入", function()
    t.it("注入成功时记录服务地址与返回值", function()
        with(function(h)
            h.names = { [".agent"] = 0x70 }
            h.inject_output = "patched 3 funcs"
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            local entry = step_named(result, "inject_code").result[1]
            t.expect(entry.success).to.equal(true)
            t.expect(entry.service).to.equal(".agent(00000070)")
            t.expect(entry.result).to.equal("patched 3 funcs")
            t.expect(h.injects[1].cmd).to.equal("RUN")
            t.expect(h.injects[1].filename).to.equal("p.lua")
        end)
    end)

    t.it("注入的代码里带着 patcher 源码和三重类型检查", function()
        with(function(h)
            h.names = { [".agent"] = 0x71 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            h.run({ hotfix_dir = "pkg", confirm = true })
            local src = h.injects[1].source
            t.expect(src).to.contain("patcher.run must be a function")
            t.expect(src).to.contain("patcher.targets must be a table")
            t.expect(src).to.contain("hotfix patcher.run failed")
        end)
    end)

    t.it("目标服务抛错时记为失败而不是整个服务崩掉", function()
        with(function(h)
            h.names = { [".agent"] = 0x72 }
            h.inject_error = "service crashed"
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result[1].error).to.match("Failed to inject code")
        end)
    end)

    t.it(
        "补丁在目标服务里抛错时记为失败并带回报错，不能因为调用本身成功就算成功",
        function()
            with(function(h)
                h.names = { [".agent"] = 0x75 }
                h.inject_failed = "hotfix patcher.run failed: boom"
                h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
                h.write("pkg/p.lua", patcher({ ".agent" }))
                local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
                t.expect(ok).to.equal(false)
                local entry = step_named(result, "inject_code").result[1]
                t.expect(entry.success).to.equal(false)
                t.expect(entry.error).to.equal("Patcher failed: hotfix patcher.run failed: boom")
                t.expect(result.guidance).to.match("禁止直接重跑整包")
            end)
        end
    )

    t.it("注入模板把 run 的返回值打印出来，带回到热更结果", function()
        with(function(h)
            h.names = { [".agent"] = 0x76 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            h.run({ hotfix_dir = "pkg", confirm = true })
            -- 在本进程里按 skynet.inject 的方式执行模板：print 被收集成 output
            local output = {}
            local env = setmetatable({
                print = function(...)
                    output[#output + 1] = table.concat({ ... }, "\t")
                end,
            }, { __index = _G })
            local chunk = assert(load(h.injects[1].source, "@inject", "t", env))
            t.expect(chunk()).to.equal("ok")
            t.expect(output).to.equal({ "ok" })
        end)
    end)

    t.it("目标服务不回包时超时返回失败，不会一直挂住热更", function()
        with(function(h)
            h.defer_fork = true
            h.names = { [".agent"] = 0x73 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result[1].error).to.match("inject timeout after 30s")
            -- 超时后还得留个协程等真结果，免得回包落地时无人知晓
            t.expect(#h.forks).to.be_gte(2)
        end)
    end)

    t.it("超时秒数可以用环境变量调小", function()
        with({ env = { hotfix_inject_timeout = "5" } }, function(h)
            h.defer_fork = true
            h.names = { [".agent"] = 0x74 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            local _, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(step_named(result, "inject_code").result[1].error).to.match("inject timeout after 5s")
        end)
    end)

    t.it("fail_fast 下第一个文件注入失败就不碰第二个文件", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'bad.lua', 'good.lua' },"))
            h.write("pkg/bad.lua", "return 1")
            h.write("pkg/good.lua", patcher({ ".agent" }))
            h.names = { [".agent"] = 0x75 }
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result).to.have_length(1)
            t.expect(h.injects).to.have_length(0)
        end)
    end)

    t.it("fail_fast=false 时坏文件不挡住好文件", function()
        with(function(h)
            h.names = { [".agent"] = 0x76 }
            h.write("pkg/hotfix.conf.lua", conf("fail_fast = false, code_files = { 'bad.lua', 'good.lua' },"))
            h.write("pkg/bad.lua", "return 1")
            h.write("pkg/good.lua", patcher({ ".agent" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "inject_code").result).to.have_length(2)
            t.expect(h.injects).to.have_length(1)
        end)
    end)

    t.it("一个 patcher 可以打到多个目标服务上", function()
        with(function(h)
            h.names = { [".a"] = 0x81, [".b"] = 0x82 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".a", ".b" }))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(step_named(result, "inject_code").result).to.have_length(2)
            t.expect(h.injects[1].addr).to.equal(0x81)
            t.expect(h.injects[2].addr).to.equal(0x82)
        end)
    end)

    t.it("code_files 为空数组时不产生 inject_code 步骤", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("code_files = {},"))
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(step_named(result, "inject_code")).to.be_nil()
        end)
    end)
end)

t.describe("hotfix 并发锁", function()
    t.it("前一次热更还没结束时拒绝第二次", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            h.on_gm = function()
                if h.nested then
                    return
                end
                h.nested = true
                h.nested_ok, h.nested_err = h.run({ hotfix_dir = "pkg", confirm = true })
            end
            local ok = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(true)
            t.expect(h.nested_ok).to.equal(false)
            t.expect(h.nested_err).to.match("Another hotfix is in progress")
        end)
    end)

    t.it("锁被持有超过上限后强制释放，不会因为一次崩溃永久锁死热更", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            h.on_gm = function()
                if h.nested then
                    return
                end
                h.nested = true
                h.time = h.time + 301
                h.nested_ok = h.run({ hotfix_dir = "pkg", confirm = true })
            end
            h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(h.nested_ok).to.equal(true)
        end)
    end)

    t.it("热更内部异常时锁照样释放", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("clearcache = true,"))
            h.on_gm = function()
                error("unexpected internal failure")
            end
            local ok, result = h.run({ hotfix_dir = "pkg", confirm = true })
            t.expect(ok).to.equal(false)
            t.expect(step_named(result, "internal_error")).to.exist()
            t.expect(result.guidance).to.match("未预期的内部错误")

            -- 锁没放掉的话这一次会被拒绝
            h.on_gm = nil
            t.expect(h.run({ hotfix_dir = "pkg", confirm = true })).to.equal(true)
        end)
    end)
end)

t.describe("hotfix 历史记录", function()
    t.it("每次执行都入历史，最新的排在最前", function()
        with(function(h)
            h.write("a/hotfix.conf.lua", conf())
            h.write("b/hotfix.conf.lua", conf())
            h.run({ hotfix_dir = "a", confirm = true })
            h.run({ hotfix_dir = "b", confirm = true })
            local ok, list = h.history({ limit = 10 })
            t.expect(ok).to.equal(true)
            t.expect(list).to.have_length(2)
            t.expect(list[1].hotfix_dir).to.equal("b")
            t.expect(list[2].hotfix_dir).to.equal("a")
            t.expect(list[1].node).to.equal("node1")
            t.expect(list[1].success).to.equal(true)
        end)
    end)

    t.it("失败的热更也要留痕", function()
        with(function(h)
            h.checksum_err = "mismatch"
            h.write("pkg/hotfix.conf.lua", conf())
            h.run({ hotfix_dir = "pkg", confirm = true })
            local _, list = h.history()
            t.expect(list[1].success).to.equal(false)
        end)
    end)

    t.it("limit 超出实际条数或为负都夹到合法范围", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf())
            h.run({ hotfix_dir = "pkg", confirm = true })
            local _, list = h.history({ limit = 999 })
            t.expect(list).to.have_length(1)
            _, list = h.history({ limit = -5 })
            t.expect(list).to.have_length(1)
            _, list = h.history({ limit = "abc" })
            t.expect(list).to.have_length(1)
        end)
    end)

    t.it("历史为空时返回空列表而不是报错", function()
        with(function(h)
            local ok, list = h.history({ limit = 10 })
            t.expect(ok).to.equal(true)
            t.expect(list).to.have_length(0)
        end)
    end)

    t.it("历史落盘成 jsonl，一行一条", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf())
            h.run({ hotfix_dir = "pkg", confirm = true })
            h.run({ hotfix_dir = "pkg", confirm = true })
            local lines = {}
            for line in fs.read(h.history_file()):gmatch("[^\n]+") do
                lines[#lines + 1] = cjson.decode(line)
            end
            t.expect(lines).to.have_length(2)
            t.expect(lines[1].hotfix_dir).to.equal("pkg")
        end)
    end)
end)

t.describe("hotfix 历史恢复", function()
    local function write_history(h, entries)
        local parts = {}
        for i, entry in ipairs(entries) do
            parts[i] = cjson.encode(entry)
        end
        fs.write(fs.join(h.root, "hotfix_history.jsonl"), table.concat(parts, "\n") .. "\n")
    end

    t.it("启动时从 jsonl 恢复历史，最新的在最前", function()
        with({
            before = function(h)
                write_history(h, {
                    { hotfix_dir = "old", success = true },
                    { hotfix_dir = "new", success = false },
                })
            end,
        }, function(h)
            local _, list = h.history({ limit = 10 })
            t.expect(list).to.have_length(2)
            t.expect(list[1].hotfix_dir).to.equal("new")
            t.expect(list[2].hotfix_dir).to.equal("old")
        end)
    end)

    t.it("坏行被跳过，不让一条脏数据毁掉整个历史", function()
        with({
            before = function(h)
                fs.write(
                    fs.join(h.root, "hotfix_history.jsonl"),
                    cjson.encode({ hotfix_dir = "a" })
                        .. "\nnot json at all\n"
                        .. "123\n"
                        .. cjson.encode({
                            hotfix_dir = "b",
                        })
                        .. "\n"
                )
            end,
        }, function(h)
            local _, list = h.history({ limit = 10 })
            t.expect(list).to.have_length(2)
            t.expect(list[1].hotfix_dir).to.equal("b")
        end)
    end)

    t.it("历史文件超过读取上限时只读尾部，并丢掉被截断的半行", function()
        with({
            before = function(h)
                local entries = {}
                for i = 1, 300 do
                    entries[i] = { seq = i, pad = string.rep("x", 180) }
                end
                write_history(h, entries)
            end,
        }, function(h)
            -- 文件约 60KB，上限 32KB，所以只应读到尾部若干条，再被 MAX_HISTORY 截到 100
            t.expect(fs.read(h.history_file()):len()).to.be_gt(32 * 1024)
            local _, list = h.history({ limit = 200 })
            t.expect(list).to.have_length(100)
            t.expect(list[1].seq).to.equal(300)
            -- 读取起点多半落在某行中间，那半行必须丢掉而不是喂给 json 解析
            t.expect(list[100].seq).to.be_gt(1)
        end)
    end)

    t.it("历史条数超过上限时只保留最新的 100 条", function()
        with({
            before = function(h)
                local entries = {}
                for i = 1, 150 do
                    entries[i] = { seq = i }
                end
                write_history(h, entries)
            end,
        }, function(h)
            local _, list = h.history({ limit = 200 })
            t.expect(list).to.have_length(100)
            t.expect(list[1].seq).to.equal(150)
            t.expect(list[100].seq).to.equal(51)
        end)
    end)

    t.it("空历史文件不影响启动", function()
        with({
            before = function(h)
                fs.write(fs.join(h.root, "hotfix_history.jsonl"), "")
            end,
        }, function(h)
            local _, list = h.history({ limit = 10 })
            t.expect(list).to.have_length(0)
        end)
    end)
end)

t.describe("hotfix dry_run", function()
    t.it("只出计划，不执行任何步骤也不写历史", function()
        with(function(h)
            h.names = { [".agent"] = 0x90 }
            h.write(
                "pkg/hotfix.conf.lua",
                conf(
                    "clearcache = true, reload_res = true, reload_sproto = true, "
                        .. "reload_orm_schema = true, code_files = { 'p.lua' },"
                )
            )
            h.write("pkg/p.lua", patcher({ ".agent" }))
            local ok, plan = h.run({ hotfix_dir = "pkg", mode = "dry_run" })
            t.expect(ok).to.equal(true)
            t.expect(plan.steps).to.equal({ "clear_cache", "reload_res", "reload_sproto", "reload_orm_schema" })
            t.expect(plan.desc).to.equal("测试补丁")
            t.expect(plan.gitsha_update).to.equal("upd1")
            t.expect(h.gm_calls).to.have_length(0)
            t.expect(h.injects).to.have_length(0)
            t.expect(fs.mode(h.history_file())).to.be_nil()
        end)
    end)

    t.it("dry_run 不需要 confirm", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf())
            t.expect(h.run({ hotfix_dir = "pkg", mode = "dry_run" })).to.equal(true)
        end)
    end)

    t.it("列出每个 patcher 解析到的目标地址", function()
        with(function(h)
            h.names = { [".agent"] = 0x91 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".agent" }))
            local _, plan = h.run({ hotfix_dir = "pkg", mode = "dry_run" })
            t.expect(plan.patchers[1].file).to.equal("p.lua")
            t.expect(plan.patchers[1].targets[1].found).to.equal(true)
            t.expect(plan.patchers[1].targets[1].address).to.equal("00000091")
        end)
    end)

    t.it("通配目标展开成每个 agent 的地址", function()
        with(function(h)
            h.entity_types = { role = { agent_count = 2 } }
            h.names = { [".entity_agent:role:1"] = 0x31, [".entity_agent:role:2"] = 0x32 }
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".entity_agent:role:*" }))
            local _, plan = h.run({ hotfix_dir = "pkg", mode = "dry_run" })
            local targets = plan.patchers[1].targets
            t.expect(targets).to.have_length(2)
            t.expect(targets[1].address).to.equal("00000031")
            t.expect(targets[2].address).to.equal("00000032")
        end)
    end)

    t.it("目标服务不存在时记成 warning 而不是整体失败", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'p.lua' },"))
            h.write("pkg/p.lua", patcher({ ".ghost" }))
            local ok, plan = h.run({ hotfix_dir = "pkg", mode = "dry_run" })
            t.expect(ok).to.equal(true)
            t.expect(plan.patchers[1].targets[1].found).to.equal(false)
            t.expect(plan.warnings[1]).to.match("Service not found: .ghost")
        end)
    end)

    t.it("patcher 本身有问题时写进 patchers 条目而不是中断预演", function()
        with(function(h)
            h.write("pkg/hotfix.conf.lua", conf("code_files = { 'bad.lua' },"))
            h.write("pkg/bad.lua", "return 1")
            local ok, plan = h.run({ hotfix_dir = "pkg", mode = "dry_run" })
            t.expect(ok).to.equal(true)
            t.expect(plan.patchers[1].error).to.equal("Patcher must return a table")
        end)
    end)

    t.it("配置或校验不过时点名是哪一步", function()
        with(function(h)
            local ok, err = h.run({ hotfix_dir = "missing", mode = "dry_run" })
            t.expect(ok).to.equal(false)
            t.expect(err.step).to.equal("load_config")

            h.checksum_err = "mismatch"
            h.write("pkg/hotfix.conf.lua", conf())
            ok, err = h.run({ hotfix_dir = "pkg", mode = "dry_run" })
            t.expect(ok).to.equal(false)
            t.expect(err.step).to.equal("verify_checksum")
            t.expect(err.error).to.equal("mismatch")
        end)
    end)
end)

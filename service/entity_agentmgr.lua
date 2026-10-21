local skynet = require "skynet"
local lfs = require "lfs"
local cmd_api = require "skyext.cmd_api"
local types = require "skyext.entity.types"
local cluster_discovery = require "skyext.cluster_discovery"
local log = require "skyext.log"

local type_name = ...
local type_config = types.get(type_name)

local function resolve_modules_dir(modules_path, start_name)
    local game_root = skynet.getenv("game_root") or "./"
    local dir = game_root .. "nodes/" .. start_name .. "/" .. modules_path:gsub("%.", "/")
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
        return dir
    end
    return nil
end

local function discover_modules(modules_path, start_name)
    local dir = resolve_modules_dir(modules_path, start_name)
    if not dir then
        return {}
    end

    local result = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            if lfs.attributes(full, "mode") == "directory" then
                local has_init = lfs.attributes(full .. "/init.lua") ~= nil
                local has_request = lfs.attributes(full .. "/request.lua") ~= nil
                if has_init or has_request then
                    -- 把「磁盘上有哪些文件」一并带给 agent：agent 据此精确 require，
                    -- 文件在却 require 不到时能直接报错，而不是当成「这个模块没有客户端协议」
                    result[#result + 1] = { name = entry, init = has_init, request = has_request }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        return a.name < b.name
    end)
    return result
end

local function module_names(modules)
    local names = {}
    for i, mod in ipairs(modules) do
        names[i] = mod.name
    end
    return names
end

local CMD = {}

local g_modules_path
local g_modules = {}

-- 两段式启动：skynet.start 只做本地准备，agent 必须等 CMD.start 送来
-- 合法的 watchdog 之后才创建，全部创建并注册完成后才算 ready。
local g_agents = {}
local g_watchdog
local g_ready = false
local g_starting = false
local g_start_error
local g_waiters = {}

local function wakeup_waiters()
    local waiters = g_waiters
    g_waiters = {}
    for _, co in ipairs(waiters) do
        skynet.wakeup(co)
    end
end

local function wait_starting()
    local co = coroutine.running()
    g_waiters[#g_waiters + 1] = co
    skynet.wait(co)
end

-- client_enabled 的类型必须拿到 watchdog 地址，否则 bind_client 无法把 fd 转发回去
local function check_watchdog(watchdog)
    if watchdog == nil then
        assert(
            not type_config.client_enabled,
            string.format("entity_agentmgr(%s) start requires conf.watchdog", type_name)
        )
        return nil
    end
    assert(
        math.type(watchdog) == "integer" and watchdog ~= 0,
        string.format("entity_agentmgr(%s) invalid conf.watchdog: %s", type_name, tostring(watchdog))
    )
    return watchdog
end

local function create_agents(agent_count, watchdog)
    local agents = {}
    local ok, err = xpcall(function()
        for i = 1, agent_count do
            -- newservice 返回时 agent 已完成 skynet.register
            local agent = skynet.newservice("entity_agent", type_name, i)
            agents[#agents + 1] = agent
            skynet.call(agent, "lua", "start", {
                modules = g_modules,
                modules_path = g_modules_path or "",
                watchdog = watchdog,
            })
            log.info("entity_agent started", "type", type_name, "index", i, "addr", agent)
        end
    end, debug.traceback)

    if not ok then
        return nil, err, agents
    end
    return agents
end

-- 启动全部 entity_agent；返回成功即表示本节点该类型已就绪，可以对外放行
function CMD.start(conf)
    conf = conf or {}
    local watchdog = check_watchdog(conf.watchdog)

    if g_start_error then
        error(g_start_error, 0)
    end

    if g_starting then
        -- 并发重复 start：等前一次结束后复用其结果
        wait_starting()
        if not g_ready then
            error(g_start_error or string.format("entity_agentmgr(%s) start failed", type_name), 0)
        end
    end

    if g_ready then
        assert(
            g_watchdog == watchdog,
            string.format(
                "entity_agentmgr(%s) already started with watchdog %s, got %s",
                type_name,
                tostring(g_watchdog),
                tostring(watchdog)
            )
        )
        return true
    end

    g_starting = true

    local agents, err, partial = create_agents(type_config.agent_count or 1, watchdog)
    if not agents then
        g_agents = partial or {}
        g_starting = false
        g_start_error = err
        log.error("entity_agentmgr start failed", "type", type_name, "err", err)
        wakeup_waiters()
        error(err, 0)
    end

    g_agents = agents
    g_watchdog = watchdog
    -- 死信队列的运维入口按节点单例，多个实体类型共用一个；起不来不该挡住实体服务
    local dlq_ok, dlq_err = pcall(skynet.uniqueservice, "entity_dlq")
    if not dlq_ok then
        log.error("entity_dlq start failed", "type", type_name, "err", dlq_err)
    end
    -- 全部 agent 创建、注册并 start 完成后，才向集群发布自己
    cluster_discovery.register({ "entity:" .. type_name })
    g_ready = true
    g_starting = false
    wakeup_waiters()

    log.info("entity_agentmgr ready", "type", type_name, "agent_count", #agents, "watchdog", watchdog)
    return true
end

-- 让每个 agent 卸载一轮，返回还留在内存里的实体总数。agent 之间并行
local function shutdown_agents()
    local remaining = 0
    local pending = #g_agents
    local waiter = {}
    for i, agent in ipairs(g_agents) do
        skynet.fork(function()
            local ok, count = pcall(skynet.call, agent, "lua", "shutdown")
            if not ok then
                log.error("entity_agent shutdown failed", "type", type_name, "index", i, "err", count)
                -- 不知道还剩多少，至少算一个，免得上层误以为已经卸干净
                count = 1
            end
            remaining = remaining + count
            pending = pending - 1
            if pending == 0 then
                skynet.wakeup(waiter)
            end
        end)
    end
    if pending > 0 then
        skynet.wait(waiter)
    end
    return remaining
end

-- 停服：先从服务发现摘掉自己，路由随之移到其他节点；再卸载全部实体（落库、释放锁、
-- 断开客户端）。卸载失败的实体每秒重试一轮，直到卸干净或超时。
-- 返回还没卸掉的实体数，0 表示可以安全退出进程
function CMD.shutdown(timeout_sec)
    local deadline = skynet.now() + (timeout_sec or 60) * 100
    if g_ready then
        cluster_discovery.unregister({ "entity:" .. type_name })
        g_ready = false
    end
    log.info("entity_agentmgr shutting down", "type", type_name)
    while true do
        local remaining = shutdown_agents()
        if remaining == 0 then
            log.info("entity_agentmgr shutdown complete", "type", type_name)
            return 0
        end
        if skynet.now() >= deadline then
            log.error("entity_agentmgr shutdown timed out", "type", type_name, "remaining", remaining)
            return remaining
        end
        log.warn("entity_agentmgr shutdown retrying", "type", type_name, "remaining", remaining)
        skynet.sleep(100)
    end
end

function CMD.is_ready()
    return g_ready
end

function CMD.agents()
    return table.move(g_agents, 1, #g_agents, 1, {})
end

skynet.start(function()
    g_modules_path = type_config.modules_path
    if g_modules_path then
        g_modules = discover_modules(g_modules_path, skynet.getenv("start"))
        log.info("discovered modules", "type", type_name, "modules", module_names(g_modules))
    end

    cmd_api.dispatch(CMD)
    log.info("entity_agentmgr waiting for start", "type", type_name, "agent_count", type_config.agent_count or 1)
end)

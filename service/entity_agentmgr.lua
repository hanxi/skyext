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
                local has_init = lfs.attributes(full .. "/init.lua")
                local has_request = lfs.attributes(full .. "/request.lua")
                if has_init or has_request then
                    result[#result + 1] = entry
                end
            end
        end
    end
    table.sort(result)
    return result
end

local CMD = {}

local g_modules_path
local g_module_names = {}

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
                modules = g_module_names,
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
    -- 全部 agent 创建、注册并 start 完成后，才向集群发布自己
    cluster_discovery.register({ "entity:" .. type_name })
    g_ready = true
    g_starting = false
    wakeup_waiters()

    log.info("entity_agentmgr ready", "type", type_name, "agent_count", #agents, "watchdog", watchdog)
    return true
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
        g_module_names = discover_modules(g_modules_path, skynet.getenv("start"))
        log.info("discovered modules", "type", type_name, "modules", g_module_names)
    end

    cmd_api.dispatch(CMD)
    log.info("entity_agentmgr waiting for start", "type", type_name, "agent_count", type_config.agent_count or 1)
end)

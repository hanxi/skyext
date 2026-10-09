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
local g_conf = {}

function CMD.start(conf)
    g_conf = conf or {}
end

skynet.start(function()
    local start_name = skynet.getenv("start")
    local agent_count = type_config.agent_count or 1
    local modules_path = type_config.modules_path

    local module_names = {}
    if modules_path then
        module_names = discover_modules(modules_path, start_name)
        log.info("discovered modules", "type", type_name, "modules", module_names)
    end

    local agents = {}
    for i = 1, agent_count do
        local agent = skynet.newservice("entity_agent", type_name, i)
        skynet.call(agent, "lua", "start", {
            modules = module_names,
            modules_path = modules_path or "",
            watchdog = g_conf.watchdog,
        })
        agents[i] = agent
        log.info("entity_agent created", "type", type_name, "index", i, "addr", agent)
    end

    cluster_discovery.register({ "entity:" .. type_name })
    log.info("entity_agentmgr started", "type", type_name, "agent_count", agent_count)

    cmd_api.dispatch(CMD)
end)

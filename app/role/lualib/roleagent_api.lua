local config = require "config"
local skynet = require "skynet"

local M = {}
local agent_count = config.get_number("agent_count") or 2

function M.calc_agent_index(rid)
    local agent_index = rid % agent_count + 1
    return agent_index
end

function M.format_agent_name(agent_index)
    return string.format("roleagent:%d", agent_index)
end

function M.format_agent_service_name(agent_index)
    return string.format(".roleagent:%d", agent_index)
end

local agent_name_cache = {}
function M.calc_agent_name(rid)
    local agent_index = M.calc_agent_index(rid)
    if agent_name_cache[agent_index] then
        return agent_name_cache[agent_index]
    end
    local agent_name = M.format_agent_service_name(agent_index)
    agent_name_cache[agent_index] = agent_name
    return agent_name
end

-- TODO: 如果 agent 重启，这里需要更新缓存
local agent_addr_cache = {}
function M.calc_agent_addr(rid)
    local agent_name = M.calc_agent_name(rid)
    if agent_addr_cache[agent_name] then
        return agent_addr_cache[agent_name]
    end

    local addr = skynet.localname(agent_name)
    if not addr then
        error(string.format("agent_name %s not exist", agent_name))
    end
    agent_addr_cache[agent_name] = addr
    return addr
end

return M

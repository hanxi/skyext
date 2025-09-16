local config = require "config"

local M = {}

local g_self_nodename = config.get("cluster_node_name") or "undefined_node"

function M.calc_rolenode(rid)
    -- TODO: 使用jchash 计算
    return "rolenode1"
end

function M.self_rolenode()
    return g_self_nodename
end

return M

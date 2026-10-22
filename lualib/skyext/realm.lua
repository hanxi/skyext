-- 区服目录的查询端。数据来自本节点的 realm 服务（service/realm.lua），
-- 首次使用时取一份快照，之后跟着变更广播更新，查询都是查内存。
--
-- 作用域四层：server（出生服）-> game（逻辑服）-> zone（战区）-> global（全服）。
-- 角色只记出生服，game / zone 每次用到时现查：合服、调战区只改目录，不改玩家数据。
local skynet = require "skynet"
local queue = require "skynet.queue"
local event_channel_api = require "skyext.event_channel_api"

local M = {}

M.SCOPES = { server = true, game = true, zone = true, global = true }

local g_dir
local g_lock = queue()
local g_listeners = {}

local function apply(dir)
    -- 广播和快照可能乱序到达，只接受更新的版本
    if g_dir and dir.revision < g_dir.revision then
        return
    end
    g_dir = dir
    for _, fn in ipairs(g_listeners) do
        local ok, err = pcall(fn, dir)
        if not ok then
            require("skyext.log").error("realm listener failed", "err", err)
        end
    end
end

local function dir()
    if not g_dir then
        g_lock(function()
            if g_dir then
                return
            end
            local service = skynet.uniqueservice("realm")
            -- 先订阅再取快照，两者之间的变更不会漏
            event_channel_api.subscribe(service, "realm_change", apply)
            apply(skynet.call(service, "lua", "snapshot"))
        end)
    end
    return g_dir
end

local function sorted_keys(map)
    local list = {}
    for k in pairs(map) do
        list[#list + 1] = k
    end
    table.sort(list)
    return list
end

-- 区服信息 { game, name, tag, status, open_time }，不存在返回 nil。返回的表不要改
function M.server(server)
    return dir().servers[server]
end

function M.game_of(server)
    local info = dir().servers[server]
    return info and info.game
end

function M.zone_of(game)
    local info = dir().games[game]
    return info and info.zone
end

function M.servers()
    return sorted_keys(dir().servers)
end

function M.games()
    return sorted_keys(dir().games)
end

function M.zones()
    return sorted_keys(dir().zones)
end

-- 跨服场景里显示的服号，如 "S3"
function M.tag_of(server)
    local info = dir().servers[server]
    return info and info.tag or server
end

-- 出生服为 server 的角色在 scope 这一层属于哪个值；目录里查不到时返回 nil
function M.scope_value(scope, server)
    assert(M.SCOPES[scope], "unknown realm scope: " .. tostring(scope))
    if scope == "global" then
        return "global"
    elseif scope == "server" then
        return dir().servers[server] and server or nil
    end
    local game = M.game_of(server)
    if scope == "game" or not game then
        return game
    end
    return M.zone_of(game)
end

-- scope 这一层当前的全部取值，作用域实体按它预加载
function M.scope_values(scope)
    assert(M.SCOPES[scope], "unknown realm scope: " .. tostring(scope))
    if scope == "global" then
        return { "global" }
    elseif scope == "server" then
        return M.servers()
    elseif scope == "game" then
        return M.games()
    end
    return M.zones()
end

-- 当前在线的网关列表，每项 { node, tcp_addr, ws_url, weight }，按节点名排序。
-- 客户端的接入地址从这里下发：网关键挂在节点租约上，节点挂掉或开始停服就会从列表里消失，
-- 所以不需要前面再挂一层会话保持的负载均衡（续接能落到任意一台网关，见会话续接设计）
function M.gates()
    local gates = dir().gates
    local list = {}
    for _, node in ipairs(sorted_keys(gates)) do
        local info = gates[node]
        list[#list + 1] = {
            node = node,
            tcp_addr = info.tcp_addr,
            ws_url = info.ws_url,
            weight = info.weight or 1,
        }
    end
    return list
end

-- 目录变化（开服、调战区、网关上下线）时回调 fn(dir)
function M.subscribe(fn)
    dir()
    g_listeners[#g_listeners + 1] = fn
end

return M

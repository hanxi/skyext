-- 实体侧的客户端会话。连接在 gate 上（service/session_gate.lua），实体只持有
-- entity.session = { gate_node, fd, key }，会话键 key = "<gate_node>/<fd>"，全集群唯一。
-- 回包和推送都发给会话所在的 gate；gate 和实体同进程时走本地消息，否则走 cluster。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

M.GATE_SERVICE = ".session_gate"

local g_sessions = {} -- key -> entity
local g_entitymgr = nil

local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = config.get("cluster_node_name")
    end
    return g_self_node
end

function M.key(gate_node, fd)
    return gate_node .. "/" .. tostring(fd)
end

local function gate_send(gate_node, cmd, ...)
    if gate_node == self_node() then
        skynet.send(M.GATE_SERVICE, "lua", cmd, ...)
        return
    end
    local ok, err = pcall(cluster.send, gate_node, M.GATE_SERVICE, cmd, ...)
    if not ok then
        log.warn("send to gate failed", "gate", gate_node, "cmd", cmd, "err", err)
    end
end

local function gate_call(gate_node, cmd, ...)
    if gate_node == self_node() then
        return skynet.call(M.GATE_SERVICE, "lua", cmd, ...)
    end
    return cluster.call(gate_node, M.GATE_SERVICE, cmd, ...)
end

-- sproto_api 的发送端：conn 是会话键
local function sender(key, pack)
    local entity = g_sessions[key]
    local session = entity and entity.session
    if not session or session.key ~= key then
        log.warn("drop a package for a session that is gone", "session", key)
        return
    end
    gate_send(session.gate_node, "push", session.fd, pack)
end

function M.init(entitymgr)
    g_entitymgr = entitymgr
    require("skyext.sproto_api").set_sender(sender)
end

-- 把会话绑到实体上，并让 gate 把之后的包转给 owner_service（本服务的名字）。
-- gate 那边会话已经断开时返回 false
function M.bind(gate_node, fd, entity, owner_service)
    local key = M.key(gate_node, fd)
    if not gate_call(gate_node, "bind", fd, self_node(), owner_service) then
        return false
    end
    g_sessions[key] = entity
    entity.session = { gate_node = gate_node, fd = fd, key = key }
    if entity.unload_timer then
        entity.unload_timer:cancel()
        entity.unload_timer = nil
    end
    log.info("session bind", "type", entity.type_name, "id", entity.id, "session", key)
    return true
end

function M.unbind(key)
    local entity = g_sessions[key]
    if not entity then
        return
    end
    g_sessions[key] = nil
    if entity.session and entity.session.key == key then
        entity.session = nil
    end
    if g_entitymgr then
        g_entitymgr:touch(entity.id)
    end
    log.info("session unbind", "type", entity.type_name, "id", entity.id, "session", key)
end

-- 断开客户端连接。解绑交给 gate 的断开通知（session_closed），这样 on_unbind_client 照常执行
function M.kick(key)
    local gate_node, fd = key:match("^(.*)/(%d+)$")
    if gate_node then
        gate_send(gate_node, "kick", math.tointeger(fd))
    end
end

-- 只在会话确实属于 expected_entity 时解绑并断开，防止误踢已经换绑的新会话
function M.unbind_kick(key, expected_entity)
    local entity = g_sessions[key]
    if not expected_entity or entity ~= expected_entity then
        return false
    end
    M.unbind(key)
    M.kick(key)
    return true
end

function M.get_entity(key)
    return g_sessions[key]
end

function M.get_obj(key)
    local entity = g_sessions[key]
    if not entity or not g_entitymgr or g_entitymgr:get(entity.id) ~= entity then
        return nil
    end
    return { entity = entity }
end

-- 在会话所绑定实体的串行队列里执行协议处理函数 f
-- 返回 true, ...     : f 已经执行，后面是它的返回值（可能为空）
-- 返回 false, reason : 请求被拒绝，f 没有执行
function M.with_request(key, f)
    local entity = g_sessions[key]
    if not entity then
        return false, "client not bound"
    end
    if not g_entitymgr then
        return false, "entity manager not ready"
    end
    local ok, result = g_entitymgr:with_loaded_entity(entity.id, function(active)
        -- 排队等待期间会话可能已经解绑，或者换绑到别的实体上
        if active ~= entity or g_sessions[key] ~= active then
            return nil
        end
        return table.pack(f())
    end)
    if not ok then
        return false, tostring(result or "entity unavailable")
    end
    if result == nil then
        return false, "client binding revoked"
    end
    return true, table.unpack(result, 1, result.n)
end

-- 请求被拒绝、且错误码无法通过协议回给客户端时的兜底：断开连接，让客户端立刻失败重连
function M.reject_client(key, reason)
    log.warn("session rejected", "session", key, "reason", reason)
    M.kick(key)
end

-- 给实体自己的客户端推一条消息。不在线时返回 false
function M.push(entity, name, msg)
    local session = entity.session
    if not session then
        return false
    end
    require("skyext.sproto_api").notify(session.key, name, msg)
    return true
end

M.middleware_cbs = {}

return M

local skynet = require "skynet"
local log = require "skyext.log"

local M = {}

local g_fd_map = {}
local g_entitymgr = nil

function M.init(entitymgr)
    g_entitymgr = entitymgr
end

function M.bind(fd, entity)
    g_fd_map[fd] = entity
    entity.fd = fd
    if entity.unload_timer then
        entity.unload_timer:cancel()
        entity.unload_timer = nil
    end
    log.info("client_ext bind", "type", entity.type_name, "id", entity.id, "fd", fd)
end

function M.unbind(fd)
    local entity = g_fd_map[fd]
    if not entity then
        return
    end
    g_fd_map[fd] = nil
    entity.fd = nil
    if g_entitymgr then
        g_entitymgr:touch(entity.id)
    end
    log.info("client_ext unbind", "type", entity.type_name, "id", entity.id, "fd", fd)
end

-- 只断开连接，不动绑定关系：解绑交给 watchdog 的 disconnect 流程，
-- 这样 on_unbind_client 等回调照常执行
function M.kick(fd)
    skynet.call(skynet.localname(".gate"), "lua", "kick", fd)
end

function M.unbind_kick(fd, expected_entity)
    local entity = g_fd_map[fd]
    if not expected_entity or entity ~= expected_entity then
        return false
    end
    M.unbind(fd)
    M.kick(fd)
    return true
end

function M.get_entity(fd)
    return g_fd_map[fd]
end

function M.get_obj(fd)
    local entity = g_fd_map[fd]
    if not entity or not g_entitymgr or g_entitymgr:get(entity.id) ~= entity then
        return nil
    end
    return { entity = entity }
end

-- 在连接所绑定 entity 的串行队列里执行协议处理函数 f
-- 返回 true, ...     : f 已经执行，后面是它的返回值（可能为空）
-- 返回 false, reason : 请求被拒绝，f 没有执行
-- 被拒绝时调用方必须给客户端回错误码或断开连接，不能静默丢弃，
-- 否则带 session 的请求会一直等到客户端超时
function M.with_request(fd, f)
    local entity = g_fd_map[fd]
    if not entity then
        return false, "client not bound"
    end
    if not g_entitymgr then
        return false, "entity manager not ready"
    end
    local ok, result = g_entitymgr:with_loaded_entity(entity.id, function(active)
        -- 排队等待期间连接可能已经解绑，或者 fd/entity 被改绑到别的对象上
        if active ~= entity or g_fd_map[fd] ~= active then
            return nil
        end
        return table.pack(f())
    end)
    if not ok then
        -- entity 未加载、租约失效或处理过程中丢锁
        return false, tostring(result or "entity unavailable")
    end
    if result == nil then
        return false, "client binding revoked"
    end
    return true, table.unpack(result, 1, result.n)
end

-- 请求被拒绝、且错误码无法通过协议回给客户端时的兜底处理：
-- 断开连接，让客户端立刻失败重连，而不是干等到超时
function M.reject_client(fd, reason)
    log.warn("client_ext reject client", "fd", fd, "reason", reason)
    local ok, err = pcall(M.kick, fd)
    if not ok then
        log.error("client_ext kick failed", "fd", fd, "err", err)
    end
end

M.middleware_cbs = {}

return M

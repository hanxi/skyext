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

function M.unbind_kick(fd)
    local entity = g_fd_map[fd]
    if entity then
        M.unbind(fd)
    end
    skynet.call(skynet.localname(".gate"), "lua", "kick", fd)
end

function M.get_entity(fd)
    return g_fd_map[fd]
end

function M.get_obj(fd)
    local entity = g_fd_map[fd]
    if not entity then
        return nil
    end
    return { entity = entity }
end

M.middleware_cbs = {}

return M

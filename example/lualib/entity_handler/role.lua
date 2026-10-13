local log = require "skyext.log"

local M = {}

M.handlers = {}

function M.handlers.get_online_info(entity)
    if not entity.fd then
        return nil
    end
    return { rid = entity.id, name = entity.data.name }
end

function M.handlers.kick(entity)
    if entity.fd then
        local client_ext = require "skyext.entity.client_ext"
        client_ext.unbind_kick(entity.fd, entity)
    end
    return true
end

function M.on_load(entity)
    log.info("role entity loaded", "rid", entity.id)
end

function M.on_unload(entity)
    log.info("role entity unloading", "rid", entity.id)
end

function M.on_bind_client(entity, fd)
    entity.fd = fd
    log.info("role client bound", "rid", entity.id, "fd", fd)
end

function M.on_unbind_client(entity)
    entity.fd = nil
    log.info("role client unbound", "rid", entity.id)
end

return M

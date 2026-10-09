local log = require "skyext.log"

local M = {}

M.handlers = {}

function M.handlers.get_info(entity)
    return { name = entity.data.name }
end

function M.handlers.set_name(entity, name)
    entity.data.name = name
    return true
end

function M.on_load(entity)
    log.info("example entity loaded", "id", entity.id)
end

function M.on_unload(entity)
    log.info("example entity unloading", "id", entity.id)
end

return M

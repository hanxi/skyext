local log = require "skyext.log"

local M = {}
M.__index = M

function M.new(entity, data)
    log.info("creating mail module", "entity_id", entity.id)
    return setmetatable({ entity = entity, data = data }, M)
end

return M

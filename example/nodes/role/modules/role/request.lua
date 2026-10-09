local log = require "skyext.log"
local time = require "skyext.time"
local res = require "skyext.res"

local M = {}

function M.login_info(request, fd, ctx)
    local entity = ctx.entity
    entity.data.last_login_time = time.now_ms()
    log.debug("test res", "hero", res.hero)
    return {
        info = {
            rid = entity.id,
            name = entity.data.name,
        },
    }
end

return M

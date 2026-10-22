local time = require "skyext.time"
local errcode = require "errcode"

local M = {}

function M.login_info(request, fd, ctx)
    local entity = ctx.entity
    entity.data.last_login_time = time.now_ms()
    return {
        code = errcode.OK,
        info = {
            rid = entity.id,
            name = entity.data.name,
        },
    }
end

return M

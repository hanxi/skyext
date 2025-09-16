local skynet = require "skynet"
local log = require "log"

local M = {}
M.__index = M

function M.new(role_obj, data)
    local obj = {
        role_obj = role_obj,
        data = data,
    }
    setmetatable(obj, M)
    log.info("creating mail object", "rid", role_obj.rid)
    return obj
end

return M

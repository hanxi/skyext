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
    log.info("creating bag object", "rid", role_obj.rid)

    data.bags = {}
    data.bags[101] = {
        res_type = 101,
        res = {
            [10086] = {
                res_size = 1,
            },
        },
    }
    return obj
end

return M

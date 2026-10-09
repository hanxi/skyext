local log = require "skyext.log"

local M = {}
M.__index = M

function M.new(entity, data)
    log.info("creating bag module", "entity_id", entity.id)
    local obj = setmetatable({ entity = entity, data = data }, M)
    if not data.bags then
        data.bags = {}
        data.bags[101] = {
            res_type = 101,
            res = {
                [10086] = {
                    res_size = 1,
                },
            },
        }
    end
    return obj
end

function M:add_item(res_type, res_id, count)
    -- 业务逻辑
end

return M

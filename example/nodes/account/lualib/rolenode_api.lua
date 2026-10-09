local types = require "skyext.entity.types"

local M = {}

function M.calc_rolenode(rid)
    return types.calc_node("role", rid)
end

return M

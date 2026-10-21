local types = require "skyext.entity.types"

local M = {}

-- 每个 game 一份排行榜：实体 ID 由 game 名确定性地算出，任何节点都能直接找到它。
-- 和 entity_types.rank.preload 里的键必须一致
function M.key(game)
    return "rank:" .. game
end

function M.id(game)
    return types.key_id(M.key(game))
end

return M

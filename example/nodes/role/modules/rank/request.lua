local router = require "skyext.entity.router"
local realm = require "skyext.realm"
local errcode = require "errcode"

local M = {}

local DEFAULT_COUNT = 10
local MAX_COUNT = 100

-- 角色只记出生服，所属 game 每次现查区服目录：合服后自动换到新 game 的排行榜
local function my_game(entity)
    return realm.game_of(entity.data.server)
end

-- 角色实体同步调用另一个实体（本 game 的排行榜）的示范。
-- rank 实体不会反过来同步调用角色，所以在角色的串行队列里 call 它不会互相等死
function M.submit(request, fd, ctx)
    local score = request.score
    if math.type(score) ~= "integer" or score < 0 then
        return { code = errcode.PARAM_ERROR }
    end
    local entity = ctx.entity
    local game = my_game(entity)
    if not game then
        return { code = errcode.RANK_UNAVAILABLE }
    end
    local ok = router.scoped_call("rank", game, "submit", entity.id, entity.data.name, score)
    if not ok then
        return { code = errcode.RANK_UNAVAILABLE }
    end
    return { code = errcode.OK }
end

function M.top(request, fd, ctx)
    local count = request.count or DEFAULT_COUNT
    if math.type(count) ~= "integer" or count < 1 then
        return { code = errcode.PARAM_ERROR }
    end
    local game = my_game(ctx.entity)
    if not game then
        return { code = errcode.RANK_UNAVAILABLE }
    end
    local ok, entries = router.scoped_call("rank", game, "top", math.min(count, MAX_COUNT))
    if not ok then
        return { code = errcode.RANK_UNAVAILABLE }
    end
    return { code = errcode.OK, entries = entries }
end

return M

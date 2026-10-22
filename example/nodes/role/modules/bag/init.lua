local orm = require "orm"
local res = require "skyext.res"

local M = {}
M.__index = M

function M.new(entity, data)
    local obj = setmetatable({ entity = entity, data = data }, M)
    -- 加载时 ORM 会给缺的字段补零值，bags 一开始就是空表而不是 nil
    if not data.bags then
        data.bags = {}
    end
    if not data.starter_granted then
        -- 新角色送的初始道具来自策划配置表。每次用的时候才去 res 里取，不在模块加载期
        -- 抄成本地常量——GM 的 reload_res 换掉的是 res 里那张表，抄过的副本不会跟着变
        for _, item in ipairs(res.param.InitItem) do
            obj:add_item(item.res_type, item.res_id, item.res_size)
        end
        data.starter_granted = true
    end
    return obj
end

function M:add_item(res_type, res_id, count)
    assert(math.type(count) == "integer" and count > 0, "item count must be a positive integer")
    local bags = self.data.bags
    if not bags[res_type] then
        bags[res_type] = { res_type = res_type, res = {} }
    end
    local res = bags[res_type].res
    local item = res[res_id]
    if item then
        item.res_size = item.res_size + count
    else
        res[res_id] = { res_id = res_id, res_size = count }
    end
end

function M:count(res_type, res_id)
    local bag = self.data.bags[res_type]
    local item = bag and bag.res[res_id]
    return item and item.res_size or 0
end

-- 转成协议用的数组形式
function M:snapshot()
    local result = {}
    for res_type, bag in pairs(self.data.bags) do
        local items = {}
        for _, item in pairs(bag.res) do
            items[#items + 1] = orm.totable(item)
        end
        table.sort(items, function(a, b)
            return a.res_id < b.res_id
        end)
        result[#result + 1] = { res_type = res_type, res = items }
    end
    table.sort(result, function(a, b)
        return a.res_type < b.res_type
    end)
    return result
end

return M

-- 比较两份 schema define，判断新的那份能不能直接读旧的那份写下的文档。
--
-- 运行期已经容忍字段增删（见 orm.decode），所以这里真正要拦的是改名和改类型：
-- 它们不会在加载时报错，只会让旧数据静静地读不出来或读成错的。
local M = {}

-- 变更级别
--   M.BREAK 不兼容：库里的文档会读错或读不出来，必须拦下
--   M.WARN  能跑，但有数据代价，需要人确认
--   M.INFO  安全
M.BREAK = "break"
M.WARN = "warn"
M.INFO = "info"

local LEVEL_ORDER = { [M.BREAK] = 1, [M.WARN] = 2, [M.INFO] = 3 }

-- 把字段压成一个可比较的签名。map/array 的键值类型也是结构的一部分，
-- 换掉同样会让旧数据对不上，所以一并算进签名。
local function signature(field)
    local tp = assert(field.type, "schema field has no type")
    if tp == "map" then
        return string.format("map<%s,%s>", field.key, field.value)
    elseif tp == "array" then
        return string.format("array<%s>", field.item)
    end
    return tp
end

local function sorted_keys(tbl)
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function add(changes, level, scope, field, message)
    changes[#changes + 1] = { level = level, scope = scope, field = field, message = message }
end

-- 同一个结构里既删了字段又加了字段，而且类型一样，多半是改名。
-- 改名在运行期的表现是"旧字段被丢弃、新字段补零值"，数据就这么没了，
-- 所以要单独拎出来说，不能只报一句"删了一个字段"。
local function pair_renames(removed, added)
    local by_sig = {}
    for _, name in ipairs(added) do
        local sig = added[name]
        by_sig[sig] = by_sig[sig] or {}
        table.insert(by_sig[sig], name)
    end
    local renames = {}
    for _, name in ipairs(removed) do
        local candidates = by_sig[removed[name]]
        if candidates and #candidates > 0 then
            renames[name] = table.remove(candidates, 1)
        end
    end
    return renames
end

local function diff_struct(changes, scope, old_fields, new_fields)
    local removed, added = {}, {}
    for _, name in ipairs(sorted_keys(old_fields)) do
        if new_fields[name] == nil then
            removed[#removed + 1] = name
            removed[name] = signature(old_fields[name])
        end
    end
    for _, name in ipairs(sorted_keys(new_fields)) do
        if old_fields[name] == nil then
            added[#added + 1] = name
            added[name] = signature(new_fields[name])
        end
    end

    local renames = pair_renames(removed, added)
    for _, name in ipairs(removed) do
        local into = renames[name]
        if into then
            add(
                changes,
                M.WARN,
                scope,
                name,
                string.format(
                    "疑似改名为 %s（类型都是 %s）：旧文档里的值不会跟着搬过去",
                    into,
                    removed[name]
                )
            )
        else
            add(
                changes,
                M.WARN,
                scope,
                name,
                "删除字段：库里已有的值从此读不到，确认这份数据不再需要"
            )
        end
    end
    local rename_targets = {}
    for _, into in pairs(renames) do
        rename_targets[into] = true
    end
    for _, name in ipairs(added) do
        if not rename_targets[name] then
            add(
                changes,
                M.INFO,
                scope,
                name,
                string.format("新增字段 %s：旧文档加载时补零值", added[name])
            )
        end
    end

    for _, name in ipairs(sorted_keys(old_fields)) do
        local new_field = new_fields[name]
        if new_field then
            local was, now = signature(old_fields[name]), signature(new_field)
            if was ~= now then
                add(
                    changes,
                    M.BREAK,
                    scope,
                    name,
                    string.format("类型从 %s 改成 %s：旧文档里的值对不上", was, now)
                )
            end
        end
    end
end

--- 比较两份 schema define（sproto2lua 的产物），返回按级别排序的变更列表。
-- 每项为 { level, scope, field, message }，scope 是结构名，field 可能为 nil。
function M.diff(old_defs, new_defs)
    local changes = {}
    for _, name in ipairs(sorted_keys(old_defs)) do
        if new_defs[name] == nil then
            add(
                changes,
                M.WARN,
                name,
                nil,
                "删除结构：如果它是某个集合的根结构，这个集合将无法加载"
            )
        else
            diff_struct(changes, name, old_defs[name], new_defs[name])
        end
    end
    for _, name in ipairs(sorted_keys(new_defs)) do
        if old_defs[name] == nil then
            add(changes, M.INFO, name, nil, "新增结构")
        end
    end

    table.sort(changes, function(a, b)
        if a.level ~= b.level then
            return LEVEL_ORDER[a.level] < LEVEL_ORDER[b.level]
        end
        if a.scope ~= b.scope then
            return a.scope < b.scope
        end
        return (a.field or "") < (b.field or "")
    end)
    return changes
end

--- 统计各级别的数量。
function M.count(changes)
    local counts = { [M.BREAK] = 0, [M.WARN] = 0, [M.INFO] = 0 }
    for _, change in ipairs(changes) do
        counts[change.level] = counts[change.level] + 1
    end
    return counts
end

--- 把一条变更渲染成一行文本。
function M.format(change)
    local where = change.field and (change.scope .. "." .. change.field) or change.scope
    return string.format("[%s] %s: %s", change.level, where, change.message)
end

return M

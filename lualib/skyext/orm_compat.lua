-- 比较两份 schema，判断新的那份能不能直接读旧的那份写下的文档。
--
-- 运行期已经容忍字段增删（见 orm.decode），所以这里真正要拦的是三件事：
-- 改类型、改名、以及重新使用删过的名字。前两件一眼能看出来；最后一件只有
-- 基线替你记着才看得出来——删字段只是不再读它，值一直躺在库里，几个版本之后
-- 有人加回一个同名字段，那份旧值就会被当成新值读出来。
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
M.signature = signature

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

local function diff_struct(changes, scope, old_fields, new_fields, retired_fields)
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
                "删除字段：库里已有的值从此读不到，这个名字之后不能再用"
            )
        end
    end

    local rename_targets = {}
    for _, into in pairs(renames) do
        rename_targets[into] = true
    end
    for _, name in ipairs(added) do
        local retired = retired_fields[name]
        if retired then
            add(
                changes,
                M.BREAK,
                scope,
                name,
                string.format(
                    "这个名字之前删过（当时是 %s）：库里还躺着那会儿写下的值，加回同名字段会把旧值当成新值读出来，换个名字",
                    retired
                )
            )
        elseif not rename_targets[name] then
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

local EMPTY = {}

local function retired_of(baseline)
    local retired = baseline.retired or EMPTY
    return retired.fields or EMPTY, retired.types or EMPTY
end

--- 比较基线和当前 schema，返回按级别排序的变更列表。
-- baseline 形如 { types = {...}, retired = { fields = {...}, types = {...} } }，
-- current 是 sproto2lua 生成的 define 表。
-- 每项为 { level, scope, field, message }，scope 是结构名，field 可能为 nil。
function M.diff(baseline, current)
    local old_types = assert(baseline.types, "baseline has no types")
    local retired_fields, retired_types = retired_of(baseline)
    local changes = {}

    for _, name in ipairs(sorted_keys(old_types)) do
        if current[name] == nil then
            add(
                changes,
                M.WARN,
                name,
                nil,
                "删除结构：如果它是某个集合的根结构，这个集合将无法加载，这个名字之后不能再用"
            )
        else
            diff_struct(changes, name, old_types[name], current[name], retired_fields[name] or EMPTY)
        end
    end
    for _, name in ipairs(sorted_keys(current)) do
        if old_types[name] == nil then
            if retired_types[name] then
                add(
                    changes,
                    M.BREAK,
                    name,
                    nil,
                    "这个结构名之前删过：库里可能还留着按旧结构写下的文档，换个名字"
                )
            else
                add(changes, M.INFO, name, nil, "新增结构")
            end
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

--- 用当前 schema 生成新基线：记下当前结构，并把这一次删掉的名字追加进墓碑。
-- 墓碑只增不减，唯一的例外是名字又出现在当前 schema 里（只有 --force 能走到这一步），
-- 这时留着它只会让之后每次检查都失败，所以清掉。
function M.build_lock(baseline, current)
    local old_types = assert(baseline.types, "baseline has no types")
    local old_fields, old_types_retired = retired_of(baseline)

    local fields, types = {}, {}
    for scope, tombstones in pairs(old_fields) do
        for name, sig in pairs(tombstones) do
            if not (current[scope] and current[scope][name]) then
                fields[scope] = fields[scope] or {}
                fields[scope][name] = sig
            end
        end
    end
    for name in pairs(old_types_retired) do
        if not current[name] then
            types[name] = true
        end
    end

    for scope, old_struct in pairs(old_types) do
        local new_struct = current[scope]
        if not new_struct then
            types[scope] = true
            -- 整个结构没了，它的字段名跟着一起退休：结构名要是哪天回来，
            -- 里面的字段名也不能直接复用
            for name, field in pairs(old_struct) do
                fields[scope] = fields[scope] or {}
                fields[scope][name] = signature(field)
            end
        else
            for name, field in pairs(old_struct) do
                if new_struct[name] == nil then
                    fields[scope] = fields[scope] or {}
                    fields[scope][name] = signature(field)
                end
            end
        end
    end

    return { types = current, retired = { fields = fields, types = types } }
end

--- 列出基线里退休的名字，按结构名、字段名排序。scope 不为 nil 时只列那一个结构。
-- 每项为 { scope, field, signature }，整个结构退休的那项没有 field。
function M.retired(baseline, scope)
    local retired_fields, retired_types = retired_of(baseline)
    local list = {}
    for name in pairs(retired_types) do
        if not scope or scope == name then
            list[#list + 1] = { scope = name }
        end
    end
    for name, tombstones in pairs(retired_fields) do
        if not scope or scope == name then
            for field, sig in pairs(tombstones) do
                list[#list + 1] = { scope = name, field = field, signature = sig }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.scope ~= b.scope then
            return a.scope < b.scope
        end
        return (a.field or "") < (b.field or "")
    end)
    return list
end

local RESERVED = {}
for word in
    ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch(
        "%a+"
    )
do
    RESERVED[word] = true
end

local function encode_key(name)
    if type(name) == "string" and name:match("^[%a_][%w_]*$") and not RESERVED[name] then
        return name
    end
    return string.format("[%q]", name)
end

local function encode_value(value, indent)
    if type(value) ~= "table" then
        return type(value) == "string" and string.format("%q", value) or tostring(value)
    end
    local keys = sorted_keys(value)
    if #keys == 0 then
        return "{}"
    end
    local inner = indent .. "    "
    local parts = { "{" }
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format("%s%s = %s,", inner, encode_key(k), encode_value(value[k], inner))
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end

--- 把基线序列化成 Lua 源码。键按字典序输出，同一份基线每次写出来都一样。
function M.encode(lock)
    return "return " .. encode_value(lock, "") .. "\n"
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

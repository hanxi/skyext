local next = next
local setmetatable = setmetatable
local getmetatable = getmetatable
local type = type
local table = table

local orm = {}
local _new_doc = nil

local ormdoc_type = setmetatable({}, {
    __tostring = function()
        return "ORM"
    end,
})

local function doc_len(doc)
    return #doc.__stage
end

local function doc_next(doc, k)
    return next(doc.__stage, k)
end

local function doc_pairs(doc)
    return pairs(doc.__stage)
end

local function doc_ipairs(doc)
    return ipairs(doc.__stage)
end

local function doc_unpack(doc, i, j)
    return table.unpack(doc.__stage, i, j)
end

local function doc_concat(doc, sep, i, j)
    return table.concat(doc.__stage, sep, i, j)
end

local function mark_dirty(doc)
    while doc do
        doc.__dirty = true
        doc.__revision = doc.__revision + 1
        doc = doc.__parent
    end
end

local function doc_change_value(doc, k, v)
    if getmetatable(v) == ormdoc_type then
        doc.__schema:_check_kv(k, v.__schema)
    elseif v ~= nil then
        doc.__schema:_check_kv(k, v)
    end
    if v ~= doc[k] then
        doc.__changed_keys[k] = true -- mark changed (even nil)
        local lv = doc.__stage[k]
        if getmetatable(lv) == ormdoc_type then
            lv.__parent = false
        end
        doc.__stage[k] = v -- current value
        mark_dirty(doc)
    end
end

local function doc_change_recursively(doc, k, v)
    local schema = doc.__schema[k]
    local lv
    if getmetatable(v) == ormdoc_type then
        assert(not v.__parent, "non-root nodes cannot be assigned to other objects")
        lv = v
    else
        lv = _new_doc(schema, v)
    end

    lv.__parent = doc
    doc_change_value(doc, k, lv)
    lv.__all_dirty = true
end

local function doc_change(doc, k, v)
    -- parse k
    k = doc.__schema:_parse_k(k)

    if type(v) == "table" then
        doc_change_recursively(doc, k, v)
    elseif doc[k] ~= v then
        doc_change_value(doc, k, v)
    end
end

-- 转为普通表
local function doc_totable(object)
    local lookup_table = {}
    local function _copy(obj)
        if type(obj) ~= "table" then
            return obj
        elseif lookup_table[obj] then
            error("not support circular reference")
        end

        local new_table = {}
        lookup_table[obj] = new_table
        for key, value in pairs(obj) do
            new_table[_copy(key)] = _copy(value)
        end

        return new_table
    end
    return _copy(object)
end

local function _clone_doc(doc)
    assert(getmetatable(doc) == ormdoc_type, "only suppor orm")
    local init = doc_totable(doc)
    return _new_doc(doc.__schema, init)
end

-- refer to table.insert()
local function doc_insert(doc, index, v)
    local len = doc_len(doc)
    if v == nil then
        v = index
        index = len + 1
    end
    assert(math.tointeger(index) and index >= 1 and index <= len + 1, "position out of bounds")

    local displaced = doc.__stage[index]
    local revision = doc.__revision
    doc[index] = v
    for i = len, index + 1, -1 do
        doc.__stage[i + 1] = doc.__stage[i]
        doc.__changed_keys[i + 1] = true
    end
    if displaced ~= nil then
        doc.__stage[index + 1] = displaced
        doc.__changed_keys[index + 1] = true
        if getmetatable(displaced) == ormdoc_type then
            displaced.__parent = doc
        end
    end
    if doc.__revision == revision then
        mark_dirty(doc)
    end
end

-- refer to table.remove()
local function doc_remove(doc, index)
    local len = doc_len(doc)
    index = index or len
    if len == 0 and index == 0 then
        return nil
    end
    assert(math.tointeger(index) and index >= 1 and index <= len + 1, "position out of bounds")
    if index > len then
        return nil
    end

    local v = doc[index]
    doc[index] = nil
    for i = index + 1, len do
        doc.__stage[i - 1] = doc.__stage[i]
        doc.__changed_keys[i - 1] = true
    end
    doc.__stage[len] = nil
    doc.__changed_keys[len] = true
    return v
end

local array_bson_mt = {
    __len = function(t)
        return rawlen(t)
    end,
}

local function copy_bson(value, seen)
    if type(value) ~= "table" then
        return value
    end
    assert(not seen[value], "cannot encode circular table")
    seen[value] = true
    local result = {}
    local is_doc = getmetatable(value) == ormdoc_type
    local schema_type = is_doc and value.__schema.type
    for k, v in pairs(value) do
        local key = schema_type == "map" and tostring(k) or k
        result[key] = copy_bson(v, seen)
    end
    if schema_type == "array" or getmetatable(value) == array_bson_mt then
        setmetatable(result, array_bson_mt)
    end
    seen[value] = nil
    return result
end

function orm.to_bson(value)
    return copy_bson(value, {})
end

_new_doc = function(schema, init)
    assert(schema, "need schema")
    assert(getmetatable(init) ~= ormdoc_type, "can not orm")

    local doc_stage = {}
    setmetatable(doc_stage, {
        __index = function(t, k)
            schema:_check_k(k)
            return rawget(t, k)
        end,
    })
    local init_copy = {}
    for k, v in pairs(init or {}) do
        init_copy[k] = v
        init[k] = nil
    end

    -- use init addr
    local doc = init or {}
    doc.__dirty = false
    doc.__all_dirty = false
    doc.__revision = 0
    doc.__parent = false
    doc.__changed_keys = {}
    doc.__stage = doc_stage
    doc.__schema = schema

    local mt = {
        __index = doc_stage,
        __newindex = doc_change,
        __pairs = doc_pairs,
        __ipairs = doc_ipairs,
        __metatable = ormdoc_type, -- avoid copy by ref

        -- 额外接口
        __next = doc_next,
        __unpack = doc_unpack,
        __concat = doc_concat,
        __insert = doc_insert,
        __remove = doc_remove,
    }
    if doc.__schema.type == "array" then
        mt.__len = doc_len
    end
    setmetatable(doc, mt)

    for k, v in pairs(init_copy) do
        if type(v) == "table" then
            if getmetatable(v) == ormdoc_type then
                if v.__parent then
                    v = _clone_doc(v)
                end
            else
                v = _new_doc(schema[k], v)
            end
        end
        doc[k] = v
    end
    return doc
end

local function _clear_dirty(doc, watched)
    -- 不可能有环
    watched = watched or {}
    if watched[doc] then
        error("why orm has circular reference")
        return
    end
    watched[doc] = true
    doc.__dirty = false
    doc.__all_dirty = false
    doc.__changed_keys = {}
    for _, v in pairs(doc) do
        if getmetatable(v) == ormdoc_type then
            _clear_dirty(v)
        end
    end
end

function orm.new(schema, init)
    local doc = _new_doc(schema, init)
    _clear_dirty(doc)
    return doc
end

local ZERO = { integer = 0, number = 0, string = "", boolean = false }

local function is_container(schema)
    return schema.type == "map" or schema.type == "array"
end

local align
-- schema 新加的字段在旧文档里没有值。补零值而不是留 nil：玩法代码不该为
-- "这个字段是上个版本加的" 多分一条支路。
local function zero_value(schema, path, dropped, seen)
    local scalar = ZERO[schema.type]
    if scalar ~= nil then
        return scalar
    end
    if is_container(schema) then
        return {}
    end
    if seen[schema] then
        -- 结构直接或间接包含自己，没有有限的零值，只能留空
        return nil
    end
    local sub = {}
    align(schema, sub, path, dropped, seen)
    return sub
end

local function sub_path(path, k)
    if path == "" then
        return tostring(k)
    end
    return path .. "." .. tostring(k)
end

-- 把存储里读出来的普通表原地对齐到当前 schema，返回被丢弃的字段路径。
align = function(schema, value, path, dropped, seen)
    if is_container(schema) then
        for k, v in pairs(value) do
            local field = schema[k]
            if field ~= nil and type(v) == "table" then
                align(field, v, sub_path(path, k), dropped, seen)
            end
        end
        return
    end

    seen[schema] = true
    for k, v in pairs(value) do
        local field = schema[k]
        if field == nil then
            value[k] = nil
            dropped[#dropped + 1] = sub_path(path, k)
        elseif type(v) == "table" then
            align(field, v, sub_path(path, k), dropped, seen)
        end
    end

    local fields = assert(schema.fields, "schema has no fields(), cannot decode")()
    for _, name in ipairs(fields) do
        if value[name] == nil then
            value[name] = zero_value(schema[name], sub_path(path, name), dropped, seen)
        end
    end
    seen[schema] = nil
end

--- 从存储里解码一份文档，返回 doc 和被丢弃的字段路径列表。
--
-- 库里躺着的文档是旧版本代码写下的，形状不一定还等于当前 schema。多出来的字段
-- 丢掉（代码已经删了它，留着只会撞在类型检查上），缺掉的字段补零值。补出来的值
-- 不算脏，不会被写回数据库。
--
-- 这样增删字段不需要任何迁移脚本；改名和改类型仍然是不兼容变更，由
-- ./bin/skyext schema check 在提交前拦下。
function orm.decode(schema, init)
    local dropped = {}
    align(schema, init, "", dropped, {})
    -- 排个序，同一份文档每次打出来的告警都一样，便于比对
    table.sort(dropped)
    return orm.new(schema, init), dropped
end

function orm.check_type(doc)
    if type(doc) ~= "table" then
        return false
    end
    local mt = getmetatable(doc)
    return mt == ormdoc_type
end

function orm.snapshot_mongo(doc)
    assert(getmetatable(doc) == ormdoc_type, "only support orm")
    local update = { ["$set"] = {}, ["$unset"] = {} }
    for k in pairs(doc.__changed_keys) do
        if doc.__stage[k] == nil then
            update["$unset"][k] = true
        end
    end
    for k, v in pairs(doc.__stage) do
        if doc.__changed_keys[k] or (getmetatable(v) == ormdoc_type and v.__dirty) then
            update["$set"][k] = copy_bson(v, {})
        end
    end
    if next(update["$set"]) == nil then
        update["$set"] = nil
    end
    if next(update["$unset"]) == nil then
        update["$unset"] = nil
    end
    return next(update) ~= nil, update, doc.__revision
end

function orm.ack_mongo(doc, revision, version)
    assert(getmetatable(doc) == ormdoc_type, "only support orm")
    assert(type(version) == "number", "version must be a number")
    local unchanged = doc.__revision == revision
    if unchanged then
        _clear_dirty(doc)
    end
    rawset(doc.__stage, "_version", version)
    return unchanged
end

function orm.is_dirty(doc)
    return doc.__dirty
end

function orm.clone(doc)
    return _clone_doc(doc)
end

function orm.is_orm(doc)
    return getmetatable(doc) == ormdoc_type
end

-- 就地热重载 schema。
-- 必须保持 old_schema 这张表以及每个 schema_obj 的引用不变：进程里所有 orm doc
-- 的类型判定、以及生成代码里 role.new 之类的闭包都持有这些引用。
-- old_schema 和 new_schema 必须是两张不同的表。传同一张表会让每个 schema_obj
-- 先被清空、再从已经被清空的自己身上取值，结果是所有类型定义全部丢失。
function orm.reload_schema(old_schema, new_schema)
    assert(old_schema, "need old_schema")
    assert(new_schema, "need new_schema")
    assert(old_schema ~= new_schema, "reload_schema needs a distinct new_schema table")
    for schema_name, schema_obj in pairs(old_schema) do
        local new_schema_obj = new_schema[schema_name]
        if new_schema_obj then
            -- 去掉 schema 的元表
            setmetatable(schema_obj, nil)
            for k, v in pairs(schema_obj) do
                schema_obj[k] = nil
            end
            -- 重新赋值
            for k, v in pairs(new_schema_obj) do
                schema_obj[k] = v
            end
            setmetatable(schema_obj, getmetatable(new_schema_obj))
        else
            old_schema[schema_name] = nil
        end
    end
    -- 新增的类型：old_schema 里还没有的 schema_name 需要补进来，
    -- 否则热更后新增的数据结构会被静默丢掉
    for schema_name, new_schema_obj in pairs(new_schema) do
        if old_schema[schema_name] == nil then
            old_schema[schema_name] = new_schema_obj
        end
    end
end

orm.next = doc_next
orm.unpack = doc_unpack
orm.concat = doc_concat
orm.insert = doc_insert
orm.remove = doc_remove
orm.totable = doc_totable

return orm

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

function orm.reload_schema(old_schema, new_schema)
    assert(old_schema, "need old_schema")
    assert(new_schema, "need new_schema")
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
end

orm.next = doc_next
orm.unpack = doc_unpack
orm.concat = doc_concat
orm.insert = doc_insert
orm.remove = doc_remove
orm.totable = doc_totable

return orm

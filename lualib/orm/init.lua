local next = next
local setmetatable = setmetatable
local getmetatable = getmetatable
local type = type
local rawset = rawset
local table = table
local sformat = string.format

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
    if not doc.__dirty then
        doc.__dirty = true
        local parent = doc.__parent
        while parent do
            if parent.__dirty then
                break
            end
            parent.__dirty = true
            parent = parent.__parent
        end
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
        if v == nil then
            if getmetatable(lv) == ormdoc_type then
                lv.__parent = false
            end
        end
        doc.__stage[k] = v -- current value
        mark_dirty(doc)
    end
end

local function doc_change_recursively(doc, k, v)
    local schema = doc.__schema[k]
    local lv = doc.__stage[k]
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

    for i = len, index, -1 do
        doc[i].__parent = false
        doc[i + 1] = doc[i]
    end
    doc[index] = v
end

-- refer to table.remove()
local function doc_remove(doc, index)
    local len = doc_len(doc)
    index = index or len

    local v = doc[index]
    doc[index] = nil -- trig a clone of doc._lastversion[index] in doc_change()

    for i = index + 1, len do
        doc[i].__parent = false
        doc[i - 1] = doc[i]
    end
    doc[len] = nil

    return v
end

local function default_pairs(t)
    return doc_pairs(t)
end

local function is_atom_type(v)
    local tp = type(v)
    if tp == "number" or tp == "string" or tp == "boolean" then
        return true
    end
    return false
end

local bson_next
local function is_skip_next(doc, v)
    if is_atom_type(v) or (bson_next(v) ~= nil) then
        return false
    end
    return true
end

local function skip_default_next(doc, k)
    local k1, v1 = next(doc.__stage, k)
    if k1 == nil then
        return k1, v1
    end

    if not is_skip_next(doc, v1) then
        return k1, v1
    end

    return skip_default_next(doc, k1)
end

bson_next = function(doc, k)
    if k ~= nil then
        k = doc.__schema:_parse_k(k)
    end

    k1, v1 = skip_default_next(doc, k)
    if k1 == nil then
        return k1, v1
    end

    if type(k1) ~= "string" then
        k1 = tostring(k1)
    end
    return k1, v1
end

local function bson_pairs(t)
    return bson_next, t, nil
end

local table_pairs = default_pairs

local function start_serialize()
    assert(table_pairs == default_pairs)
    table_pairs = bson_pairs
end

local function stop_serialize()
    assert(table_pairs == bson_pairs)
    table_pairs = default_pairs
end

-- 处理序列化 map 时把 key 改为 string 类型
function orm.with_bson_encode_context(f, ...)
    start_serialize()
    local ok, ret = pcall(f, ...)
    stop_serialize()
    if not ok then
        error(ret)
    end
    return ret
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
    doc.__parent = false
    doc.__changed_keys = {}
    doc.__stage = doc_stage
    doc.__schema = schema

    local mt = {
        __index = doc_stage,
        __newindex = doc_change,
        __pairs = function(t)
            -- 正常使用时是 default_pairs , 序列化 bson 时是 bson_pairs
            return table_pairs(t)
        end,
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
                else
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

local function unset_all_dirty(tab, visited)
    if not visited then
        visited = {}
    end

    if visited[tab] then
        return
    end

    visited[tab] = true

    tab.__all_dirty = false
    for k, v in pairs(tab) do
        if getmetatable(v) == ormdoc_type then
            unset_all_dirty(v, visited)
        end
    end
end

local function _commit_mongo(doc, result, path_array, depth)
    doc.__dirty = false
    local changed_keys = doc.__changed_keys
    local stage = doc.__stage
    local dirty = false

    path_array = path_array or {}
    depth = depth or 1

    if next(changed_keys) ~= nil then
        dirty = true
        for k in next, changed_keys do
            local v = stage[k]
            changed_keys[k] = nil
            if result then
                if doc.__schema.type == "array" then
                    path_array[depth] = k - 1
                else
                    path_array[depth] = k
                end

                local key = table.concat(path_array, ".", 1, depth)
                path_array[depth] = nil

                if v == nil then
                    result["$unset"][key] = true
                else
                    if not is_skip_next(doc, v) then
                        result["$set"][key] = v
                    end
                end
                result._n = result._n + 1
            end
        end
    end

    for k, v in pairs(stage) do
        if getmetatable(v) == ormdoc_type and v.__dirty then
            if doc.__schema.type == "array" then
                path_array[depth] = k - 1
            else
                path_array[depth] = k
            end

            if result then
                local change
                if v.__all_dirty then
                    change = _commit_mongo(v, nil, path_array, depth + 1)
                else
                    local n = result._n
                    _commit_mongo(v, result, path_array, depth + 1)
                    if n ~= result._n then
                        change = true
                    end
                end

                if change then
                    if v.__all_dirty then
                        local key = table.concat(path_array, ".", 1, depth)
                        if result["$set"][key] == nil then
                            if not is_skip_next(doc, v) then
                                result["$set"][key] = v
                                result._n = result._n + 1
                            end
                        end
                    end
                    dirty = true
                end
                unset_all_dirty(v)
            else
                local change = _commit_mongo(v, nil, path_array, depth + 1)
                dirty = dirty or change
            end

            path_array[depth] = nil -- 统一在循环末尾清理路径
        end
    end
    return dirty
end

function orm.commit_mongo(doc)
    local result = {
        ["$set"] = {},
        ["$unset"] = {},
        _n = 0,
    }
    _commit_mongo(doc, result)
    result._n = nil
    if next(result["$set"]) == nil then
        result["$set"] = nil
    end
    if next(result["$unset"]) == nil then
        result["$unset"] = nil
    end
    local is_dirty = true
    if next(result) == nil then
        is_dirty = false
    end
    return is_dirty, result
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

orm.next = doc_next
orm.unpack = doc_unpack
orm.concat = doc_concat
orm.insert = doc_insert
orm.remove = doc_remove
orm.totable = doc_totable

return orm

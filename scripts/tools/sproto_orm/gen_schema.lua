-- 测试命令 lua tools/gen_schema.lua test/schema.lua test/schema_define.lua

local sformat = string.format
local tconcat = table.concat
local tinsert = table.insert

local output_filename = arg[1]
local input_filename = arg[2]

-- 检查文件名是否提供
if not input_filename then
    input_filename = "schema_define.lua"
end
if not output_filename then
    output_filename = "schema.lua"
end

local function read_file(path)
    local handle = io.open(path, "r")
    local ret = handle:read("*a")
    handle:close()
    return ret
end

local function write_file(path, data, mode)
    local handle = io.open(path, mode)
    handle:write(data)
    handle:close()
end

local s = read_file(input_filename)
local schema_define = load(s)()
print("Loaded schema define from: " .. input_filename)

local function interp(s, tab)
    return (s:gsub("($%b{})", function(w)
        return tab[w:sub(3, -2)] or w
    end))
end

local function sort_pairs(t, f)
    local a = {}
    for n in pairs(t) do
        table.insert(a, n)
    end
    table.sort(a, f)
    local i = 0
    local iter = function()
        i = i + 1
        if a[i] == nil then
            return nil
        else
            return a[i], t[a[i]]
        end
    end
    return iter
end

local head = sformat(
    [[
-- Code generated from %s
-- DO NOT EDIT!

]],
    input_filename
)

local schema_base = [[
local orm = require "orm"
local tointeger = math.tointeger
local sformat = string.format

local number = setmetatable({
    type = "number",
}, {
    __tostring = function()
        return "schema_number"
    end,
})

local integer = setmetatable({
    type = "integer",
}, {
    __tostring = function()
        return "schema_integer"
    end,
})

local string = setmetatable({
    type = "string",
}, {
    __tostring = function()
        return "schema_string"
    end,
})

local boolean = setmetatable({
    type = "boolean",
}, {
    __tostring = function()
        return "schema_boolean"
    end,
})

local function _parse_k_tp(k, need_tp)
    if need_tp == integer then
        local nk = tointeger(k)
        if tointeger(k) == nil then
            error(sformat("not equal k type. need integer, real: %s, k: %s, need_tp: %s", type(k), tostring(k), tostring(need_tp)))
        end
        return nk
    elseif need_tp == string then
        return tostring(k)
    end
    error(sformat("not support need_tp type: %s, k: %s", tostring(need_tp), tostring(k)))
end

local function _check_k_tp(k, need_tp)
    if need_tp == integer then
        if (type(k) ~= "number") or (tointeger(k) == nil) then
            error(sformat("not equal k type. need integer, real: %s, k: %s, need_tp: %s", type(k), tostring(k), tostring(need_tp)))
        end
        return
    elseif need_tp == string then
        if type(k) ~= "string" then
            error(sformat("not equal k type. need string, real: %s, k: %s, need_tp: %s", type(k), tostring(k), tostring(need_tp)))
        end
        return
    end
    error(sformat("not support need_tp type: %s, k: %s", tostring(need_tp), tostring(k)))
end

local function _check_v_tp(v, need_tp)
    if need_tp == integer then
        if (type(v) ~= "number") or (tointeger(v) == nil) then
            error(sformat("not equal v type. need integer, real: %s, v: %s, need_tp: %s", type(v), tostring(v), tostring(need_tp)))
        end
        return
    elseif need_tp == number then
        if type(v) ~= "number" then
            error(sformat("not equal v type. need number, real: %s, v: %s, need_tp: %s", type(v), tostring(v), tostring(need_tp)))
        end
        return
    elseif need_tp == string then
        if type(v) ~= "string" then
            error(sformat("not equal v type. need string, real: %s, v: %s, need_tp: %s", type(v), tostring(v), tostring(need_tp)))
        end
        return
    elseif need_tp == boolean then
        if type(v) ~= "boolean" then
            error(sformat("not equal v type. need boolean, real: %s, v: %s, need_tp: %s", type(v), tostring(v), tostring(need_tp)))
        end
        return
    end
    if v ~= need_tp then
        error(sformat("not equal v type. need_tp: %s, v: %s", tostring(need_tp), tostring(v)))
    end
end

local function parse_k_func(need_tp)
    return function(self, k)
        return _parse_k_tp(k, need_tp)
    end
end

local function check_k_func(need_tp)
    return function(self, k)
        _check_k_tp(k, need_tp)
    end
end

local function check_kv_func(k_need_tp, v_need_tp)
    return function(self, k, v)
        _check_k_tp(k, k_need_tp)
        _check_v_tp(v, v_need_tp)
    end
end

local function parse_k(self, k)
    local schema = self[k]
    if not schema then
        error(sformat("not exist key: %s", k))
    end
    return k
end

local function check_k(self, k)
    local schema = self[k]
    if not schema then
        error(sformat("not exist key: %s", k))
    end
end

local function check_kv(self, k, v)
    local schema = self[k]
    if not schema then
        error(sformat("not exist key: %s", k))
    end

    _check_v_tp(v, schema)
end

]]

local defines = {}

local tmpl_message = [[
setmetatable(${name}, {
    __tostring = function()
        return "schema_${name}"
    end,
})
${fields_str}
${name}._parse_k = parse_k
${name}._check_k = check_k
${name}._check_kv = check_kv
${name}.new = function(init)
    return orm.new(${name}, init)
end
local ${name}_fields = {${fields_list_str}}
${name}.fields = function()
    return ${name}_fields
end
]]

local tmpl_map = [[
setmetatable(map_${kv_type}, {
    __tostring = function()
        return "schema_map_${kv_type}"
    end,
    __index = function(t, k)
        return ${value_type}
    end,
})
map_${kv_type}._parse_k = parse_k_func(${key_type})
map_${kv_type}._check_k = check_k_func(${key_type})
map_${kv_type}._check_kv = check_kv_func(${key_type}, ${value_type})
map_${kv_type}.new = function(init)
    return orm.new(map_${kv_type}, init)
end
]]

local tmpl_arr = [[
setmetatable(arr_${value_type}, {
    __tostring = function()
        return "schema_arr_${value_type}"
    end,
    __index = function(t, k)
        return ${value_type}
    end,
})
arr_${value_type}._parse_k = parse_k_func(integer)
arr_${value_type}._check_k = check_k_func(integer)
arr_${value_type}._check_kv = check_kv_func(integer, ${value_type})
arr_${value_type}.new = function(init)
    return orm.new(arr_${value_type}, init)
end
]]

local type2name = {
    double = "number",
    integer = "integer",
    binary = "string",
    string = "string",
    boolean = "boolean",
}

local function typename(t)
    return type2name[t] or t
end

local returns = {}
tinsert(returns, "return {")

local forbiden_fields = {
    ["new"] = true,
    ["fields"] = true,
}
local bodys = {}
local maps = {}
local arrs = {}
local obj_names = {}
for name, fields in sort_pairs(schema_define) do
    tinsert(defines, sformat('local %s = { type = "struct" }', name))
    tinsert(returns, sformat("    %s = %s,", name, name))

    local fields_line = {}
    local fields_list = {}
    for field_name, field in sort_pairs(fields) do
        assert(forbiden_fields[field_name] == nil, sformat("forbiden fields <%s.%s>", name, field_name))
        local tp_name = field.type
        if tp_name == "map" then
            local key_type = typename(field.key)
            local value_type = typename(field.value)
            local kv_type = sformat("%s_%s", key_type, value_type)
            if not maps[kv_type] then
                maps[kv_type] = true
                local obj_name = sformat("map_%s", kv_type)
                assert(obj_names[obj_name] == nil, sformat("obj name duplicate <%s>", obj_name))
                obj_names[obj_name] = true
                tinsert(bodys, interp(tmpl_map, { key_type = key_type, value_type = value_type, kv_type = kv_type }))
                tinsert(defines, sformat('local map_%s = { type = "map"}', kv_type))
                tinsert(returns, sformat("    map_%s = map_%s,", kv_type, kv_type))
            end
        elseif tp_name == "array" then
            local field_type = typename(field.item)
            if not arrs[field_type] then
                arrs[field_type] = true
                local obj_name = sformat("arr_%s", field_type)
                assert(obj_names[obj_name] == nil, sformat("obj name duplicate <%s>", obj_name))
                obj_names[obj_name] = true
                tinsert(bodys, interp(tmpl_arr, { value_type = field_type }))
                tinsert(defines, sformat('local arr_%s = { type = "array" }', field_type))
                tinsert(returns, sformat("    arr_%s = arr_%s,", field_type, field_type))
            end
        end

        local field_type = typename(tp_name)
        if tp_name == "map" then
            field_type = sformat("map_%s_%s", typename(field.key), typename(field.value))
        elseif tp_name == "array" then
            field_type = sformat("arr_%s", typename(field.item))
        end
        tinsert(fields_line, sformat("%s.%s = %s", name, field_name, field_type))
        tinsert(fields_list, sformat("%q", field_name))
    end
    local fields_str = tconcat(fields_line, "\n")
    local fields_list_str = tconcat(fields_list, ",")
    local obj_name = name
    assert(obj_names[obj_name] == nil, sformat("obj name duplicate <%s>", obj_name))
    obj_names[obj_name] = true
    tinsert(bodys, interp(tmpl_message, { name = name, fields_str = fields_str, fields_list_str = fields_list_str }))
end

tinsert(returns, "}")

local ret_content = head
    .. schema_base
    .. tconcat(defines, "\n")
    .. "\n\n"
    .. tconcat(bodys, "\n")
    .. "\n"
    .. tconcat(returns, "\n")
    .. "\n"

write_file(output_filename, ret_content, "w")
print("successfully generated schema to: " .. output_filename)

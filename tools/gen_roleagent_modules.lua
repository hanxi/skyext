local lfs = require "lfs"

local function fetch_modules()
    local modules = {}
    local modules_path = SCRIPT_DIRECTORY .. "../service/game/roleagent/modules"
    for file in lfs.dir(modules_path) do
        if file ~= "." and file ~= ".." then
            local f = modules_path .. "/" .. file
            local attr = lfs.attributes(f)
            assert(type(attr) == "table")
            if attr.mode == "directory" then
                local request_file = f .. "/request.lua"
                if lfs.attributes(request_file) then
                    modules[#modules + 1] = file
                end
            end
        end
    end
    return modules
end

-- 排序遍历表的键值对（按键排序）
local function pairs_by_key(t, sort_func)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end

    -- 默认按升序排序（支持字符串或数字 key）
    table.sort(keys, sort_func or function(a, b)
        return a < b
    end)

    -- 返回迭代器
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k then
            return k, t[k]
        end
    end
end

local function write_file(path, data, mode)
    local handle = io.open(path, mode)
    handle:write(data)
    handle:close()
end

local function interp(s, tab)
    return (s:gsub("($%b{})", function(w)
        return tab[w:sub(3, -2)] or w
    end))
end

local sformat = string.format

local requires = {}
local inits = {}
local mod_loads = {}

local modules = fetch_modules()
for _, m in pairs_by_key(modules) do
    requires[#requires + 1] = interp([[local ${m}_request = require "modules.${m}.request"]], { m = m })
    inits[#inits + 1] = interp([[    sproto_api.register_module("${m}", client, ${m}_request)]], { m = m })

    if m ~= "role" then
        requires[#requires + 1] = interp([[local ${m} = require "modules.${m}"]], { m = m })
        mod_loads[#mod_loads + 1] = interp(
            [[
    if role_data.modules.${m} == nil then
        role_data.modules.${m} = {}
    end
    role_obj.modules.${m} = ${m}.new(role_obj, role_data.modules.${m})
]],
            { m = m }
        )
    end
end

local requires_str = table.concat(requires, "\n")
local head = sformat(
    [[
-- Code generated from tools/gen_roleagent_modules.lua
-- DO NOT EDIT!

local schema = require "orm.schema"
local sproto_api = require "sproto_api"
%s

local M = {}
]],
    requires_str
)

local inits_str = table.concat(inits, "\n")
local body = sformat(
    [[
function M.init(client)
%s
end

]],
    inits_str
)

local mod_loads_str = table.concat(mod_loads, "\n")
local load_mod = sformat(
    [[
function M.load(role_obj, role_data)
    if role_data.modules == nil then
        role_data.modules = {}
    end

    role_obj.modules = {}

%send
]],
    mod_loads_str
)

local foot = [[
return M
]]

local output_filename = SCRIPT_DIRECTORY .. "../service/game/roleagent/modules/init.lua"
local content = head .. body .. load_mod .. foot
write_file(output_filename, content, "w")

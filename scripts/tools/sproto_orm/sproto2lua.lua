-- 测试命令 lua scripts/tools/sproto_orm/sproto2lua.lua output.lua example/schema/role.sproto

local directory = assert(arg[0]):match("^(.*)[/\\][^/\\]+$") or "."
package.path = directory .. "/../../../3rd/sprotodump/?.lua;" .. package.path

local sformat = string.format

-- 写入文件内容
local outfilename = arg[1]

-- 检查文件名是否提供
if not outfilename then
    print("No output file provided")
    return
end

-- 读取 sproto 文件内容
local sproto_files = {}
for i = 2, #arg do
    table.insert(sproto_files, arg[i])
end

-- 检查文件名是否提供
if #sproto_files == 0 then
    print("No .sproto file provided")
    return
end
table.sort(sproto_files)
local str_sproto_files = table.concat(sproto_files, " ")

local sprotodump_parse_core = require "core"
local sprotodump_util = require "util"
local sprotodump_serpent = require "serpent"

local trunk_list = {}
for _, file in ipairs(sproto_files) do
    trunk_list[#trunk_list + 1] = { sprotodump_util.read_file(file), file }
end
local _, build = sprotodump_parse_core.gen_trunk(trunk_list)

local cls_map = {}
local protocols = {}
for k, v in pairs(build.protocol) do
    if v.request then
        protocols[v.request] = true
    end
    if v.response then
        protocols[v.response] = true
    end
end
for k, v in pairs(build.type) do
    -- 排除协议
    if not protocols[k] then
        cls_map[k] = {}
        for kk, vv in pairs(v) do
            if type(vv) == "table" and vv.name then
                if vv.array == true and vv.map_keyfield and vv.map_valuefield then
                    cls_map[k][vv.name] = {
                        type = "map",
                        key = vv.map_keyfield.typename,
                        value = vv.map_valuefield.typename,
                    }
                elseif vv.array == true then
                    cls_map[k][vv.name] = {
                        type = "array",
                        item = vv.typename,
                    }
                else
                    cls_map[k][vv.name] = {
                        type = vv.typename,
                    }
                end
            end
        end
    end
end

-- 打开文件
local outfile = assert(io.open(outfilename, "w"))

local fmt_file_header = sformat(
    [[
-- Code generated from %s
-- DO NOT EDIT!
return ]],
    str_sproto_files
)

local s = sprotodump_serpent.block(cls_map, { comment = false })
local out_content = table.concat({ fmt_file_header, s }, "")

-- 写入文件内容
assert(outfile:write(out_content))
assert(outfile:close())

print("successfully generated schema define to: " .. outfilename)

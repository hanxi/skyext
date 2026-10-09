local parse_core = require "core"
local util = require "util"

local function _gen_trunk_list(sproto_file, namespace)
    local trunk_list = {}
    for i, v in ipairs(sproto_file) do
        namespace = namespace and util.file_basename(v) or nil
        table.insert(trunk_list, { util.read_file(v), v, namespace })
    end
    return trunk_list
end

local sproto_file = {}
for i = 1, #arg do
    local file = arg[i]
    if file:match("%.sproto$") then
        table.insert(sproto_file, file)
        print("Adding sproto file: " .. file)
    else
        print("Invalid file format: " .. file)
        return
    end
end
local m = require "module.spb"
local trunk_list = _gen_trunk_list(sproto_file, true)
local trunk, build = parse_core.gen_trunk(trunk_list)
local param = {
    outfile = "build/proto/sproto.spb",
}
m(trunk, build, param)

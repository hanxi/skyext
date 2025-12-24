SERVICE_ARGS = ...

local raw_error = error
function _G.error(...)
    print(...)
    print(debug.traceback())
    raw_error(...)
end

local args = {}
for word in string.gmatch(SERVICE_ARGS, "%S+") do
    table.insert(args, word)
end

-- :后面的部分会被忽略
SERVICE_NAME = string.gsub(args[1], ":.*", "", 1)

local main, pattern

local err = {}
for pat in string.gmatch(LUA_SERVICE, "([^;]+);*") do
    local filename = string.gsub(pat, "?", SERVICE_NAME)
    local f, msg = loadfile(filename)
    if not f then
        table.insert(err, msg)
    else
        pattern = pat
        main = f
        break
    end
end

if not main then
    error(table.concat(err, "\n"))
end

LUA_SERVICE = nil
package.path, LUA_PATH = LUA_PATH, nil
package.cpath, LUA_CPATH = LUA_CPATH, nil
local service_path = string.match(pattern, "(.*/)[^/?]+$")

if service_path then
    service_path = string.gsub(service_path, "?", SERVICE_NAME)
    package.path = service_path .. "?.lua;" .. package.path
    package.path = service_path .. "?/init.lua;" .. package.path
    SERVICE_PATH = service_path
else
    local p = string.match(pattern, "(.*/).+$")
    SERVICE_PATH = p
end

_G.require = (require "skynet.require").require

-- 服务独有的库
package.path = package.path .. SERVICE_PATH .. SERVICE_NAME .. "/lualib/?.lua;"
package.path = package.path .. SERVICE_PATH .. SERVICE_NAME .. "/lualib/?/init.lua;"

-- 进程独有的库
local skynet = require "skynet"
local root = skynet.getenv("root")
local start = skynet.getenv("start")
package.path = package.path .. root .. "app/" .. start .. "/lualib/?.lua;"
package.path = package.path .. root .. "app/" .. start .. "/lualib/?/init.lua;"

-- 加载 skyext
local ok, err = pcall(require, "skyext")
if not ok then
    error(err)
end

main(select(2, table.unpack(args)))

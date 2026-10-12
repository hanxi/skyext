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
    SERVICE_PATH = service_path
else
    local p = string.match(pattern, "(.*/).+$")
    SERVICE_PATH = p
end

_G.require = (require "skynet.require").require

-- 搜索优先级：服务独有库 > 节点根目录 > 节点独有库 > 游戏公共库 > 引擎库 > skynet 库
-- package.path 初始值来自 paths.conf.lua 的 lua_path（游戏公共库 > 引擎库 > skynet 库）

local skynet = require "skynet"
local game_root = skynet.getenv("game_root") or "./"
local start = skynet.getenv("start")

-- 节点独有库 prepend（优先于游戏/引擎/skynet）
local node_lualib = game_root
    .. "nodes/"
    .. start
    .. "/lualib/?.lua;"
    .. game_root
    .. "nodes/"
    .. start
    .. "/lualib/?/init.lua;"
package.path = node_lualib .. package.path

-- 节点根目录 prepend（优先于节点独有库）
if service_path then
    package.path = service_path .. "?.lua;" .. service_path .. "?/init.lua;" .. package.path
end

-- 服务独有库 prepend（最高优先级）
if SERVICE_PATH then
    package.path = SERVICE_PATH
        .. SERVICE_NAME
        .. "/lualib/?.lua;"
        .. SERVICE_PATH
        .. SERVICE_NAME
        .. "/lualib/?/init.lua;"
        .. package.path
end

-- 加载 skytest 覆盖率（未部署或未开启时静默跳过）
pcall(require, "skytest.cov")

-- 加载 skyext
local ok, err = pcall(require, "skyext")
if not ok then
    error(err)
end

main(select(2, table.unpack(args)))

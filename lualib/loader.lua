SERVICE_ARGS = ...

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
package.path , LUA_PATH = LUA_PATH, nil
package.cpath , LUA_CPATH = LUA_CPATH, nil
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

require("skyext")

if LUA_PRELOAD then
	local f = assert(loadfile(LUA_PRELOAD))
	f(table.unpack(args))
	LUA_PRELOAD = nil
end

_G.require = (require "skynet.require").require

main(select(2, table.unpack(args)))

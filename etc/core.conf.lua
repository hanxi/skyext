root = "./"

luaservice = root .. "app/" .. start .. "/?.lua;"
luaservice = luaservice .. root .. "app/?/main.lua;"
luaservice = luaservice .. root .. "app/" .. start .. "/?/main.lua;"
luaservice = luaservice .. root .. "service/?.lua;"
luaservice = luaservice .. root .. "service/?/main.lua;"
luaservice = luaservice .. root .. "skynet/service/?.lua;"

lua_path = root .. "?.lua;"
lua_path = lua_path .. root .. "lualib/?.lua;"
lua_path = lua_path .. root .. "lualib/?/init.lua;"
lua_path = lua_path .. root .. "skynet/lualib/?.lua;"

lua_cpath = root .. "luaclib/?.so;"
lua_cpath = lua_cpath .. root .. "skynet/luaclib/?.so;"

cpath = root .. "skynet/cservice/?.so;"
snax = root .. "service/?.lua;"

lualoader = root .. "lualib/loader.lua"
preload = root .. "lualib/preload.lua"

thread = 8
bootstrap = "snlua bootstrap"
harbor = 0

logservice = "snlua"
logger = "logger"

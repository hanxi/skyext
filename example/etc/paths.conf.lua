-- 服务搜索路径（节点 → 游戏服务 → 引擎服务 → skynet 服务）
luaservice = game_root .. "nodes/" .. start .. "/?.lua;"
luaservice = luaservice .. game_root .. "nodes/?/main.lua;"
luaservice = luaservice .. game_root .. "nodes/" .. start .. "/?/main.lua;"
luaservice = luaservice .. game_root .. "service/?.lua;"
luaservice = luaservice .. game_root .. "service/?/main.lua;"
luaservice = luaservice .. skyext_root .. "service/?.lua;"
luaservice = luaservice .. skyext_root .. "service/?/main.lua;"
luaservice = luaservice .. skyext_root .. "skynet/service/?.lua;"

-- Lua 库搜索路径（游戏库 → 引擎库 → skynet 库）
lua_path = game_root .. "lualib/?.lua;"
lua_path = lua_path .. game_root .. "lualib/?/init.lua;"
lua_path = lua_path .. game_root .. "build/lualib/?.lua;"
lua_path = lua_path .. game_root .. "build/lualib/?/init.lua;"
lua_path = lua_path .. skyext_root .. "lualib/?.lua;"
lua_path = lua_path .. skyext_root .. "lualib/?/init.lua;"
lua_path = lua_path .. skyext_root .. "skynet/lualib/?.lua;"

-- C 模块搜索路径（游戏 → 引擎 → skynet）
lua_cpath = game_root .. "luaclib/?.so;"
lua_cpath = lua_cpath .. skyext_root .. "luaclib/?.so;"
lua_cpath = lua_cpath .. skyext_root .. "skynet/luaclib/?.so;"

-- C 服务搜索路径（游戏 → 引擎 → skynet）
cpath = game_root .. "cservice/?.so;"
cpath = cpath .. skyext_root .. "cservice/?.so;"
cpath = cpath .. skyext_root .. "skynet/cservice/?.so;"

snax = game_root .. "service/?.lua;"

lualoader = skyext_root .. "lualib/loader.lua"

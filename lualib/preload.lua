-- 服务独有的库
package.path = package.path .. SERVICE_PATH .. SERVICE_NAME .. "/lualib/?.lua;"
package.path = package.path .. SERVICE_PATH .. SERVICE_NAME .. "/lualib/?/init.lua;"

-- 进程独有的库
local skynet = require "skynet"
local root = skynet.getenv("root")
local start = skynet.getenv("start")
package.path = package.path .. root .. "app/" .. start .. "/lualib/?.lua;"
package.path = package.path .. root .. "app/" .. start .. "/lualib/?/init.lua;"

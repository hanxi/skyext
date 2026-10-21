-- 节点停服钩子。停服流程本身在 service/node_shutdown.lua，由 GM 命令 shutdown 触发。
local skynet = require "skynet"

local M = {}

local function service()
    return skynet.uniqueservice("node_shutdown")
end

-- 启动停服编排服务（同时注册 GM 命令 shutdown）。节点启动时调用一次
function M.start()
    return service()
end

-- 停服时回调本服务的 cmd 命令。phase：
--   stop_accepting  卸载实体之前：关掉对外入口（gate、HTTP 端口），不再放新请求进来
--   release         实体全部落库之后、进程退出之前：释放其余资源
function M.add_hook(phase, cmd)
    return skynet.call(service(), "lua", "add_hook", phase, skynet.self(), cmd)
end

return M

local skynet = require "skynet"

local M = {}

local g_CMD = {}

local function merge(CMD)
    for cmd, f in pairs(CMD) do
        g_CMD[cmd] = f
    end
end

-- 接管 lua 消息分发就意味着这个服务能应答 collect_metrics，于是顺手把它挂到
-- .metrics 上。队列积压、内存、CPU 这些运行时数据不该等业务声明了指标才可见。
-- 延迟 require 是为了断开 cmd_api <-> metrics_api 的循环依赖。
local function join_metrics()
    require("skyext.metrics_api").ensure_registered()
end

function M.register(CMD)
    merge(CMD)
end

function M.dispatch(CMD)
    merge(CMD)
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = g_CMD[cmd]
        if not f then
            error(string.format("Unknown command: %s", cmd))
        end
        skynet.ret(skynet.pack(f(...)))
    end)
    join_metrics()
end

function M.dispatch_socket(CMD, SOCKET)
    merge(CMD)
    skynet.dispatch("lua", function(_, _, cmd, subcmd, ...)
        if cmd == "socket" then
            local f = SOCKET[subcmd]
            f(...)
            -- socket api don't need return
        else
            local f = g_CMD[cmd]
            if not f then
                error("Unknown command:", cmd)
            end
            skynet.ret(skynet.pack(f(subcmd, ...)))
        end
    end)
    join_metrics()
end

return M

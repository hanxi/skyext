local skynet = require "skynet"

local M = {}

local g_CMD = {}

function M.register(CMD)
    for cmd, f in pairs(CMD) do
        g_CMD[cmd] = f
    end
end

function M.dispatch(CMD)
    for cmd, f in pairs(CMD) do
        g_CMD[cmd] = f
    end
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = g_CMD[cmd]
        if not f then
            error(string.format("Unknown command: %s", cmd))
        end
        skynet.ret(skynet.pack(f(...)))
    end)
end

function M.dispatch_socket(CMD, SOCKET)
    for cmd, f in pairs(CMD) do
        g_CMD[cmd] = f
    end
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
end

return M

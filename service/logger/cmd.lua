local skynet = require "skynet"
local global = require "global"

local M = {}

function M.put(record)
    global.bucket:put(record)
end

function M.close()
    global.bucket:close()
    return skynet.self()
end

function M.reload()
    global.bucket:reload()
    return skynet.self()
end

return M

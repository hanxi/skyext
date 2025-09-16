local skynet = require "skynet"
local timer = require "timer"
local config = require "config"
local log = require "log"

local M = {}
M.__index = M
local role_offline_unload_sec = config.get_number("role_offline_unload_sec")

function M.new(role_mgr, rid, data)
    local obj = {
        role_mgr = role_mgr,
        rid = rid,
        data = data,
        fd = nil, -- 绑定的客户端 fd
    }
    setmetatable(obj, M)
    log.info("creating role object", "rid", rid, "name", data.name)
    return obj
end

function M:bind_fd(fd)
    self.fd = fd
    log.info("binding role", "rid", self.rid, "fd", fd)
    if self.offline_unload_timer then
        self.offline_unload_timer:cancel()
    end
end

function M:unbind_fd()
    self.fd = nil
    log.info("unbinding role", "rid", self.rid)

    self.offline_unload_timer = timer.timeout("role_offline_unload", role_offline_unload_sec, function()
        if self.fd == nil then
            self.role_mgr.unload_role(self.rid)
        end
    end)
end

return M

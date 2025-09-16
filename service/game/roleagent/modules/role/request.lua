local skynet = require "skynet"
local log = require "log"
local time = require "time"

local M = {}

function M:login_info(fd, client_obj)
    log.info("login_info", "fd", fd, "client_fd", client_obj.fd, "obj_fd", client_obj.role_obj.fd, "role_obj", client_obj.role_obj)
    client_obj.role_obj.data.last_login_time = time.now_ms()
    return {
        info = {
            rid = client_obj.role_obj.rid,
            name = client_obj.role_obj.data.name,
        },
    }
end

return M

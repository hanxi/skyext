-- 预定义的协议号及协议名字
-- [0, 128) skynet，read skynet.lua
local p = {
    PTYPE_LOG = 128,
    PTYPE_LOG_NAME = "log",

    PTYPE_LOG_ERR = 129,
    PTYPE_LOG_ERR_NAME = "log-err",
}

return p

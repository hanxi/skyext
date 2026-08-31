local M = {}

M.OK = 0
M.NOT_THIS_NODE = 1 -- 非当前游戏节点，自动切到对应的游戏节点
M.IN_OTHER_NODE = 2 -- 角色已在其他游戏节点，弹提示稍后重试
M.ROLE_NOT_EXIST = 3 -- 角色不存在
M.LOCAK_FAILED = 4 -- 角色锁定服务失败，弹提示稍后重试
M.ROLE_TOO_MANY = 5 -- 角色数量超过限制
M.DB_ERROR = 6 -- 数据库操作错误
M.TOKEN_ERROR = 7 -- token 错误
M.PROTO_CHECKSUM = 8 -- proto_checksum 错误
M.SERVER_NOT_EXIST = 9 -- 服务器不存在
M.PARAM_ERROR = 10 -- 参数错误
M.AUTH_FAILED = 11 -- 鉴权失败

M.MONGO_DUPLICATE_KEY = 11000

-- TODO: 读取配表

setmetatable(M, {
    __index = function(t, k)
        local v = rawget(t, k)
        if v ~= nil then
            return v
        end
        error("Invalid error code: " .. tostring(k))
    end,
})

return M

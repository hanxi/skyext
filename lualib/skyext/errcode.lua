local M = {}

M.OK = 0
M.NOT_THIS_NODE = 1
M.IN_OTHER_NODE = 2
M.LOCK_FAILED = 4
M.DB_ERROR = 6
M.PARAM_ERROR = 10
M.AUTH_FAILED = 11

-- Entity 系统错误码
M.ENTITY_NOT_FOUND = 20
M.ENTITY_LOCK_FAILED = 21
M.ENTITY_LOAD_FAILED = 22

M.MONGO_DUPLICATE_KEY = 11000

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

local M = {}

M.OK = 0
M.IN_OTHER_NODE = 2
M.LOCK_FAILED = 4
M.DB_ERROR = 6
M.PARAM_ERROR = 10
M.AUTH_FAILED = 11

-- Entity 系统错误码
M.ENTITY_NOT_FOUND = 20
M.ENTITY_LOCK_FAILED = 21
M.ENTITY_LOAD_FAILED = 22
M.SESSION_CLOSED = 23
-- 这条会话续接不了：重放缓冲溢出、客户端报的计数越界、这类实体压根没启用会话层。
-- 和 AUTH_FAILED 区分开：客户端收到这个要重新走 login，而不是重试 resume。
M.RESUME_UNAVAILABLE = 24
-- 这个 request id 的响应已经被幂等缓存淘汰了。不重新执行，让客户端重走流程——
-- 对扣费、抽卡来说，悄悄执行第二遍比报错危险得多
M.REQUEST_EXPIRED = 25
-- 这个 request id 上一次是另一条协议。客户端把 request id 计数器重置了（续接不重建
-- 会话，服务端的幂等缓存还在），再往下走就会把别人的响应当成这次请求的结果
M.REQUEST_CONFLICT = 26

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

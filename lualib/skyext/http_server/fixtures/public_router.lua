-- 测试用路由：仅供 lualib/skyext/http_server/ 下的测试使用
local M = {
    GET = {},
    POST = {},
}

M.GET["/public/ping"] = function(req, res)
    res.write_json({ scope = "public", path = req.path })
end

M.POST["/public/echo"] = function(req, res)
    local body = req.read_json() or {}
    res.write_json({ scope = "public", echo = body.msg })
end

-- 写完响应又写一次：模拟路由实现出错，验证 agent 不会把字节流写乱
M.GET["/public/double"] = function(_, res)
    res.write_json({ first = true })
    res.write_json({ second = true })
end

-- 什么都不写就返回：keep-alive 下客户端会一直等，验证 agent 的兜底
M.GET["/public/silent"] = function() end

return M

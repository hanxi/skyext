-- 测试用路由：仅供 lualib/skyext/http_server/init.test.lua 使用
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

return M

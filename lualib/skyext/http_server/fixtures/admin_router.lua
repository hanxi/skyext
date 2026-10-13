-- 测试用路由：仅供 lualib/skyext/http_server/init.test.lua 使用
local M = {
    GET = {},
}

M.GET["/admin/ping"] = function(req, res)
    res.write_json({ scope = "admin", path = req.path })
end

return M

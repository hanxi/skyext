local errcode = require "errcode"

local M = {}

function M.get_bag(request, fd, ctx)
    return { code = errcode.OK, bags = ctx.entity.modules.bag:snapshot() }
end

return M

local M = {}

function M.get_bag(request, fd, ctx)
    local bag = ctx.entity.modules.bag
    return { items = bag.data }
end

return M

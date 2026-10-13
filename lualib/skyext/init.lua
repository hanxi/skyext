-- 扩展skynet功能
local skynet = require "skynet.manager"

-- 说明：这里不再覆盖 _G.next / table.unpack / table.concat / table.insert / table.remove。
-- ORM 文档的遍历与数组操作请使用 orm 模块导出的显式接口（orm.next/unpack/concat/insert/remove），
-- 保持标准库为原生语义，避免全局副作用影响第三方库与 skynet 自身实现。

skynet.init(function()
    -- 初始化失败时直接抛出：skynet.init_service 使用 debug.traceback 作为消息处理器，
    -- 可以拿到完整堆栈，不需要在这里 pcall 后重新包装错误信息。
    require("skyext.config").init()
    require("skyext.log").init()
end)

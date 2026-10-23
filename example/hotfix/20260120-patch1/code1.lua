-- 在每个 role 实体 agent 里读一次示例配表，返回值出现在 hotfix 结果的 inject_code 步骤里，
-- 能直接看出 reload_res 之后目标服务拿到的是哪个版本。
-- 顶层只允许 local 与表构造（见 Patcher 契约），require 写在 run 里
local patcher = {}

-- 通配按 entity_types.role.agent_count 展开成 .entity_agent:role:1 … :N
patcher.targets = { ".entity_agent:role:*" }

function patcher.run()
    local res = require "skyext.res"
    -- hotfix_demo 在懒加载目录，第一次访问时才从 sharetable 取，拿到的就是重载后的内容
    return res.hotfix_demo.version
end

return patcher

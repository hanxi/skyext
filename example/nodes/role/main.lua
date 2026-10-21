-- 逻辑节点：承载实体。示例里同时带一个 gate（同进程部署），玩家连哪个节点的 gate 都能进游戏，
-- 实体落在哪个节点由实体系统决定。只做逻辑节点时去掉 gate_port 配置即可
local skynet = require "skynet"
local config = require "skyext.config"
local log = require "skyext.log"
local launcher = require "launcher"

local function launcher_entities()
    for _, type_name in ipairs({ "role", "rank" }) do
        local mgr = skynet.newservice("entity_agentmgr", type_name)
        skynet.call(mgr, "lua", "start")
    end
    -- 示例运营命令（发系统邮件）
    skynet.newservice("admin")
end

skynet.start(function()
    log.info("role start begin")
    launcher.launcher_node()
    launcher_entities()
    if config.get("gate_port") then
        launcher.launcher_gate()
    end
    log.info("role start finished")
    skynet.exit()
end)

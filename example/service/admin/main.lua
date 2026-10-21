-- 示例运营命令。不是引擎能力，演示非实体服务怎么经可靠消息改实体的数据
local skynet = require "skynet"
local gm_api = require "skyext.gm_api"
local router = require "skyext.entity.router"
local time = require "skyext.time"

local GM_CMD = {}

-- 非实体服务给实体发可靠消息的示范：消息落库后由收件人自己的 handler 收下
GM_CMD.send_mail = {
    desc = "给玩家发一封系统邮件，可带一个附件",
    params = {
        rid = "收件人",
        title = "标题",
        content = "正文",
        res_type = "附件资源分类（可选）",
        res_id = "附件资源id（可选）",
        res_size = "附件数量（可选）",
    },
    handler = function(params)
        local rid = math.tointeger(tonumber(params.rid))
        if not rid or type(params.title) ~= "string" or params.title == "" then
            return false, "rid and title are required"
        end
        -- role_db_api 加载时就会连 mongo，只在真要发邮件时才拉进来
        local role_db_api = require "role_db_api"
        if not role_db_api.exists(rid) then
            return false, "role not found"
        end
        local attach
        if params.res_type then
            local res_type = math.tointeger(tonumber(params.res_type))
            local res_id = math.tointeger(tonumber(params.res_id))
            local res_size = math.tointeger(tonumber(params.res_size))
            if not res_type or not res_id or not res_size or res_size <= 0 then
                return false, "invalid attachment"
            end
            attach = { { res_type = res_type, res_id = res_id, res_size = res_size } }
        end
        local mail = {
            title = params.title,
            content = params.content,
            send_time = time.now_ms(),
            attach = attach,
        }
        return true, router.reliable_send("role", rid, "recv_mail", { mail })
    end,
}

skynet.start(function()
    gm_api.register(GM_CMD)
end)

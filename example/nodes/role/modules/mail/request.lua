local router = require "skyext.entity.router"
local role_db_api = require "role_db_api"
local errcode = require "errcode"
local time = require "skyext.time"
local log = require "skyext.log"

local M = {}

local MAX_TITLE_LEN = 64
local MAX_CONTENT_LEN = 1024

local function valid_text(s, max_len)
    return type(s) == "string" and s ~= "" and #s <= max_len
end

function M.list(request, fd, ctx)
    return { code = errcode.OK, mails = ctx.entity.modules.mail:list() }
end

-- 跨实体写入的示范：不直接改别人的数据，而是给对方发一条可靠消息，由对方自己的
-- handler（entity_handler/role.lua 的 recv_mail）在它的串行队列里收下。
-- 消息先落库再投递，收件人离线、在别的节点、节点正在重启都不会丢
function M.send(request, fd, ctx)
    local to_rid = request.to_rid
    if math.type(to_rid) ~= "integer" or not valid_text(request.title, MAX_TITLE_LEN) then
        return { code = errcode.PARAM_ERROR }
    end
    if request.content ~= nil and not valid_text(request.content, MAX_CONTENT_LEN) then
        return { code = errcode.PARAM_ERROR }
    end
    -- 角色类型没开 auto_create，发给不存在的 rid 会让消息永远投不出去，先挡掉
    if not role_db_api.exists(to_rid) then
        return { code = errcode.ROLE_NOT_EXIST }
    end
    local entity = ctx.entity
    local mail = {
        title = request.title,
        content = request.content,
        send_time = time.now_ms(),
        sender = { rid = entity.id, name = entity.data.name },
    }
    local msg_id = router.reliable_send("role", to_rid, "recv_mail", { mail })
    log.info("mail sent", "from", entity.id, "to", to_rid, "msg_id", msg_id)
    return { code = errcode.OK }
end

function M.claim(request, fd, ctx)
    if math.type(request.mail_id) ~= "integer" then
        return { code = errcode.PARAM_ERROR }
    end
    if not ctx.entity.modules.mail:claim(request.mail_id) then
        return { code = errcode.MAIL_NOT_FOUND }
    end
    return { code = errcode.OK }
end

return M

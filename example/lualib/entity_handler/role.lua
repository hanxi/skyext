local log = require "skyext.log"

local M = {}

M.handlers = {}

function M.handlers.get_online_info(entity)
    if not entity.session then
        return nil
    end
    return { rid = entity.id, name = entity.data.name }
end

function M.handlers.kick(entity)
    if entity.session then
        local session = require "skyext.entity.session"
        session.unbind_kick(entity.session.key, entity)
    end
    return true
end

-- 可靠消息的 handler：最后一个参数是 msg_id。消息至少投递一次，
-- 拿 msg_id 当邮件 id，重复投递时 mail 模块会认出来并跳过
function M.handlers.recv_mail(entity, mail, msg_id)
    mail.mail_id = msg_id
    if entity.modules.mail:receive(mail) then
        log.info("mail received", "rid", entity.id, "mail_id", msg_id)
    end
end

function M.on_load(entity)
    log.info("role entity loaded", "rid", entity.id)
end

function M.on_unload(entity)
    log.info("role entity unloading", "rid", entity.id)
end

-- entity.session 由 skyext.entity.session 维护，这里只放业务上的上下线逻辑
function M.on_bind_client(entity, session_key)
    log.info("role client bound", "rid", entity.id, "session", session_key)
end

function M.on_unbind_client(entity)
    log.info("role client unbound", "rid", entity.id)
end

return M

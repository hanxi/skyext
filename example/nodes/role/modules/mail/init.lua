local config = require "skyext.config"
local orm = require "orm"

local M = {}
M.__index = M

local DEFAULT_MAX_MAILS = 100

local function max_mails()
    return config.get_number("mail_max_count") or DEFAULT_MAX_MAILS
end

function M.new(entity, data)
    if not data.mails then
        data.mails = {}
    end
    return setmetatable({ entity = entity, data = data }, M)
end

local function older(a, b)
    if a.send_time ~= b.send_time then
        return a.send_time < b.send_time
    end
    return a.mail_id < b.mail_id
end

-- 收下一封邮件。可靠消息是至少一次投递，同一个 mail_id 第二次来直接跳过。
-- 返回是否真的收下了
function M:receive(mail)
    local mails = self.data.mails
    if mails[mail.mail_id] then
        return false
    end
    mails[mail.mail_id] = mail

    local count, oldest = 0, nil
    for _, m in pairs(mails) do
        count = count + 1
        if not oldest or older(m, oldest) then
            oldest = m
        end
    end
    if count > max_mails() then
        mails[oldest.mail_id] = nil
    end
    return true
end

-- 新邮件在前
function M:list()
    local result = {}
    for _, m in pairs(self.data.mails) do
        local mail = orm.totable(m)
        -- 加载时 ORM 会给缺的字段补零值，系统邮件的发件人读回来是 { rid = 0, name = "" }
        if mail.sender and (mail.sender.rid or 0) == 0 then
            mail.sender = nil
        end
        result[#result + 1] = mail
    end
    table.sort(result, function(a, b)
        return older(b, a)
    end)
    return result
end

-- 领取附件并删掉邮件。返回是否找到了这封邮件
function M:claim(mail_id)
    local mail = self.data.mails[mail_id]
    if not mail then
        return false
    end
    local bag = self.entity.modules.bag
    for _, item in ipairs(mail.attach or {}) do
        bag:add_item(item.res_type, item.res_id, item.res_size)
    end
    self.data.mails[mail_id] = nil
    return true
end

return M

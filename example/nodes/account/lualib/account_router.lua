local log = require "skyext.log"
local config = require "skyext.config"
local jwt = require "jwt"
local role_db_api = require "role_db_api"
local user_db_api = require "user_db_api"
local id_generator = require "skyext.id_generator"
local errcode = require "errcode"
local time = require "skyext.time"
local role_name_api = require "role_name_api"
local realm = require "skyext.realm"
local res = require "skyext.res"

-- 配置是在 skyext 的 skynet.init 回调里注入的，本文件可能被服务 chunk 在加载期 require 到，
-- 顶层读取只会拿到 nil 并永久缓存，因此统一改成惰性读取
local g_max_role_count
local function max_role_count()
    if not g_max_role_count then
        g_max_role_count = config.get_number("max_role_count") or 5
    end
    return g_max_role_count
end

-- 登录 token 一律走 Authorization: Bearer。放在 URL query 里会被写进访问日志、
-- 代理日志、Referer 和浏览器历史，等于把登录凭据四处抄送
local function bearer_token(req)
    local auth = req.header and req.header["authorization"]
    -- 同名头出现多次时 httpd 给的是 table，这种请求一律按没带 token 处理
    if type(auth) ~= "string" then
        return nil
    end
    return auth:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(%S+)$")
end

-- 解析 JSON body。read_json 对空 body、坏 JSON 和 JSON 标量都返回 nil，
-- 不判断就直接索引是这个文件以前的崩溃点
local function read_body(res, req)
    local b, err = req.read_json()
    if not b then
        log.debug("invalid request body", "path", req.path, "err", err)
        res.write_json({ code = errcode.PARAM_ERROR })
        return nil
    end
    return b
end

-- 校验登录 token。不通过时已经把应答写回去了，调用方直接 return。
local function verify_token(res, token)
    local data, err, kind = jwt.verify_login(token)
    if not data then
        if kind == "config" then
            -- 密钥不可用（没配 / 还是示例里的公开默认值）：是部署问题，不是调用方的错
            log.error("request rejected, login_jwt_secret is unusable", "reason", err)
        else
            -- token 是登录凭据，不能进日志
            log.warn("jwt failed", "err", err)
        end
        res.write_json({ code = errcode.TOKEN_ERROR })
        return nil
    end
    return data
end

-- 名字只做最基本的检查：非空、不超长、不含控制字符。敏感词之类交给接入方。
-- 长度上限取自策划配置表，每次校验时现读：GM 的 reload_res 换掉 res 里的表之后
-- 立刻生效，不用重启节点
local function valid_role_name(name)
    if type(name) ~= "string" or name == "" or name:find("%c") then
        return false
    end
    return #name <= res.param.NameLimit
end

local M = {
    GET = {},
    POST = {},
}

-- 开发用登录：按账号名直接签发登录 token，没有任何密码校验。
-- 正式环境的 token 应由 SDK/平台登录服务在验明身份后签发，这个接口必须关掉
-- （dev_login_enable 不配就是关的）。
M.POST["/dev_login"] = function(req, res)
    if not config.get_boolean("dev_login_enable") then
        return res.write(404, "not found")
    end
    local b = read_body(res, req)
    if not b then
        return
    end
    local account = b.account
    if type(account) ~= "string" or not account:match("^[%w_]+$") or #account > 64 then
        return res.write_json({ code = errcode.PARAM_ERROR })
    end
    local token, err = jwt.sign_login({ account = account })
    if not token then
        log.error("dev_login cannot sign token", "reason", err)
        return res.write_json({ code = errcode.TOKEN_ERROR })
    end
    log.warn("dev_login issued a token without authentication", "account", account)
    return res.write_json({ code = errcode.OK, token = token })
end

-- 服务器列表，来自区服目录。不需要登录；不暴露 game / zone，那是服务端的事。
-- 最新开放的服标为推荐
M.GET["/servers"] = function(_, res)
    local servers = {}
    local recommended
    for _, server in ipairs(realm.servers()) do
        local info = realm.server(server)
        local entry = {
            server = server,
            name = info.name,
            tag = realm.tag_of(server),
            status = info.status,
            open_time = info.open_time,
        }
        servers[#servers + 1] = entry
        if info.status == "open" and (not recommended or (info.open_time or 0) > (recommended.open_time or 0)) then
            recommended = entry
        end
    end
    if recommended then
        recommended.recommended = true
    end
    return res.write_json({ code = errcode.OK, servers = servers })
end

local function get_roles(account, query)
    return role_db_api.get_roles(account, query, { _id = false, rid = 1, server = 1, name = 1 })
end

M.GET["/roles"] = function(req, res)
    local data = verify_token(res, bearer_token(req))
    if not data then
        return
    end

    local q = req.parse_query()
    local account = data.account
    local query = {}
    local server = q.server
    if server and server ~= "" then
        -- 检查服务器是否存在
        if not realm.server(server) then
            return res.write_json({
                code = errcode.SERVER_NOT_EXIST,
            })
        end
        query.server = server
    end
    local roles = get_roles(account, query)
    log.debug("get_roles", "account", account, "roles", roles)
    return res.write_json({
        code = errcode.OK,
        roles = roles,
    })
end

M.POST["/create_role"] = function(req, res)
    local data = verify_token(res, bearer_token(req))
    if not data then
        return
    end
    local b = read_body(res, req)
    if not b then
        return
    end

    local account = data.account
    -- 如果是首次进来，会创建用户 user
    local user = user_db_api.ensure_get_user(account)
    if not user then
        log.warn("login ensure_get_user failed", "account", account)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end

    local server = b.server
    local info = type(server) == "string" and realm.server(server)
    -- 只能在开放的服建角；角色只记出生服，所属 game 以后用区服目录现查
    if not info or info.status ~= "open" then
        return res.write_json({
            code = errcode.SERVER_NOT_EXIST,
        })
    end

    local name = b.name
    if not valid_role_name(name) then
        return res.write_json({
            code = errcode.PARAM_ERROR,
        })
    end

    -- max_role_count 是单个区服的上限。占名额和建角之间的每一步失败都要把名额还回去，
    -- 否则玩家会平白少一个格子
    local slot, slot_err = user_db_api.reserve_role_slot(account, server, max_role_count())
    if slot == nil then
        log.error("create_role reserve slot failed", "account", account, "server", server, "err", slot_err)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end
    if not slot then
        log.warn("create_role too many roles for account", "account", account, "max", max_role_count())
        return res.write_json({
            code = errcode.ROLE_TOO_MANY,
        })
    end

    local rid = id_generator.newid() -- 分配唯一id
    -- 名字在出生服内唯一，先占名字再建角
    local reserved, reason = role_name_api.reserve(server, name, rid)
    if not reserved then
        user_db_api.release_role_slot(account, server)
        return res.write_json({
            code = reason == "taken" and errcode.NAME_TAKEN or errcode.DB_ERROR,
        })
    end

    local role_doc = {
        server = server,
        name = name,
        create_time = time.now_ms(),
    }
    local ret = role_db_api.create(rid, account, role_doc)
    if not ret then
        log.error("create_role role_db_api.create failed", "account", account, "name", name)
        role_name_api.release(server, name)
        user_db_api.release_role_slot(account, server)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end

    local query = { server = server, rid = rid }
    local roles = get_roles(account, query)
    log.debug("create_role get_roles", "account", account, "roles", roles)
    if #roles ~= 1 then
        log.error("create_role get_roles failed", "account", account, "roles", roles)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end
    local role = roles[1]

    return res.write_json({
        code = errcode.OK,
        role = role,
    })
end

return M

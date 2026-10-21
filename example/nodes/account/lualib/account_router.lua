local log = require "skyext.log"
local config = require "skyext.config"
local jwt = require "jwt"
local role_db_api = require "role_db_api"
local user_db_api = require "user_db_api"
local id_generator = require "skyext.id_generator"
local errcode = require "errcode"
local time = require "skyext.time"
local rolenode_api = require "rolenode_api"

-- 配置是在 skyext 的 skynet.init 回调里注入的，本文件可能被服务 chunk 在加载期 require 到，
-- 顶层读取只会拿到 nil 并永久缓存，因此统一改成惰性读取
local g_server2game
local function server2game()
    if not g_server2game then
        g_server2game = assert(config.get_table("server2game"), "server2game is not configured")
    end
    return g_server2game
end

local g_max_role_count
local function max_role_count()
    if not g_max_role_count then
        g_max_role_count = config.get_number("max_role_count") or 5
    end
    return g_max_role_count
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

local MAX_NAME_LEN = 32

-- 名字只做最基本的检查：非空、不超长、不含控制字符。敏感词之类交给接入方
local function valid_role_name(name)
    return type(name) == "string" and name ~= "" and #name <= MAX_NAME_LEN and not name:find("%c")
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
    local b = req.read_json()
    local account = b and b.account
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

local function get_roles(account, query)
    return role_db_api.get_roles(account, query, { _id = false, rid = 1, server = 1, name = 1 })
end

M.GET["/roles"] = function(req, res)
    local q = req.parse_query()
    local data = verify_token(res, q.token)
    if not data then
        return
    end

    local account = data.account
    local query = {}
    local server = q.server
    if server and server ~= "" then
        -- 检查服务器是否存在
        if not server2game()[server] then
            return res.write_json({
                code = errcode.SERVER_NOT_EXIST,
            })
        end
        query.server = server
    end
    local roles = get_roles(account, query)
    log.debug("get_roles", "account", account, "roles", roles)
    for _, role in pairs(roles) do
        local rolenode = rolenode_api.calc_rolenode(role.rid)
        role.rolenode = rolenode
    end

    return res.write_json({
        code = errcode.OK,
        roles = roles,
    })
end

M.POST["/create_role"] = function(req, res)
    local b = req.read_json()
    local data = verify_token(res, b.token)
    if not data then
        return
    end

    -- 检查 account 的角色数量
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
    local game = server2game()[server]
    if not game then
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

    -- max_role_count 是单个区服的上限
    local query = {
        server = server,
    }
    local rids = role_db_api.get_roles(account, query)
    if #rids >= max_role_count() then
        log.warn("create_role too many roles for account", "account", account, "max", max_role_count())
        return res.write_json({
            code = errcode.ROLE_TOO_MANY,
        })
    end

    -- TODO: 同名检测(全服同名还是单服同名?)

    -- 创建新的角色
    local data = {
        server = server,
        game = game,
        name = name,
        create_time = time.now_ms(),
    }
    local rid = id_generator.newid() -- 分配唯一id
    local ret = role_db_api.create(rid, account, data)
    if not ret then
        log.error("create_role role_db_api.create failed", "account", account, "name", name)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end

    query.rid = rid
    local roles = get_roles(account, query)
    log.debug("create_role get_roles", "account", account, "roles", roles)
    if #roles ~= 1 then
        log.error("create_role get_roles failed", "account", account, "roles", roles)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end
    local role = roles[1]
    local rolenode = rolenode_api.calc_rolenode(rid)
    role.rolenode = rolenode

    return res.write_json({
        code = errcode.OK,
        role = role,
    })
end

return M

local log = require "log"
local config = require "config"
local jwt = require "jwt"
local role_db_api = require "role_db_api"
local id = require "id_generator"
local errcode = require "errcode"
local time = require "time"
local rolenode_api = require "rolenode_api"

local login_jwt_secret = config.get("login_jwt_secret")
local server2game = config.get_table("server2game")
local max_role_count = config.get_number("max_role_count") or 5

local M = {
    GET = {},
    POST = {},
}

local function get_roles(account, query)
    return role_db_api.get_roles(account, query, { _id = false, rid = 1, server = 1, name = 1 })
end

M.GET["/roles"] = function(req, res)
    log.debug("begin get roles", req, res)
    local q = req.parse_query()

    local data, err = jwt.verify(q.token, login_jwt_secret)
    if not data then
        log.warn("jwt failed", "err", err, "token", q.token)
        return res.write_json({
            code = errcode.TOKEN_ERROR,
        })
    end

    local account = data.account
    local query = {}
    local server = q.server
    if server and server ~= "" then
        -- 检查服务器是否存在
        if not server2game[server] then
            return res.write_json({
                code = errcode.SERVER_NOT_EXIST,
            })
        end
        query.server = server
    end
    local roles = get_roles(account, query)
    log.debug("get_roles", "token", token, "account", account, "roles", roles)
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
    log.debug("begin get roles", req, res)
    local b = req.read_json()
    local data, err = jwt.verify(b.token, login_jwt_secret)
    if not data then
        log.warn("jwt failed", "err", err, "token", b.token)
        return res.write_json({
            code = errcode.TOKEN_ERROR,
        })
    end

    -- 检查 account 的角色数量
    local account = data.account
    local server = b.server
    local query = {
        server = server,
    }
    local rids = role_db_api.get_roles(account, query)
    if #rids > max_role_count then
        log.warn("create_role too many roles for account", "account", account, "max", max_role_count)
        return res.write_json({
            code = errcode.ROLE_TOO_MANY,
        })
    end
    local game = server2game[server]
    if not game then
        return res.write_json({
            code = errcode.SERVER_NOT_EXIST,
        })
    end

    -- TODO: 限制单服角色数量

    -- TODO: 同名检测(全服同名还是单服同名?)

    -- 创建新的角色
    local name = b.name
    local data = {
        server = server,
        game = game,
        name = name,
        create_time = time.now_ms(),
    }
    local rid = id.newid() -- 分配唯一id
    local ret = role_db_api.create(rid, account, data)
    if not ret then
        log.error("create_role role_db_api.create failed", "account", account, "name", name)
        return res.write_json({
            code = errcode.DB_ERROR,
        })
    end

    query.rid = rid
    local roles = get_roles(account, query)
    log.debug("create_role get_roles", "token", token, "account", account, "roles", roles)
    if #roles ~= 1 then
        log.error("create_role get_roles failed", "token", token, "account", account, "roles", roles)
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

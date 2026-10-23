-- Lua 客户端 SDK：Account HTTP 层。服务器列表、角色管理、网关发现与开发登录。
-- 接口语义见 docs/guide/login.md；TypeScript 对等实现是 sdk/ts/ 的 AccountClient。
-- 会话层（连网关、login/resume/ping）在 skyext.client.session，两者互不依赖。
local httpc = require "skyext.httpc"
local cjson = require "cjson.safe"
local errcode = require "skyext.errcode"
local log = require "skyext.log"

local M = {}

local Account = {}
Account.__index = Account

-- conf:
--   hosts  Account 服务地址列表，如 { "http://127.0.0.1:8080" }。
--          随机挑起点，传输失败换下一台；单地址传一个即可
function M.new(conf)
    local hosts = assert(conf.hosts, "account.new needs conf.hosts")
    assert(#hosts > 0, "account.new needs a non-empty hosts list")
    return setmetatable({
        hosts = hosts,
        cursor = math.random(#hosts),
    }, Account)
end

-- 从随机偏移开始逐台尝试，直到拿到有效响应。只在传输失败/非 200 时轮换；
-- code ≠ OK 的业务错误是有效应答，原样返回给调用方判断。
-- 成功返回解码后的响应表，全部 host 都失败返回 nil。
function Account:request(method, url, token, body)
    local n = #self.hosts
    local start = self.cursor
    self.cursor = self.cursor % n + 1
    for i = 0, n - 1 do
        local host = self.hosts[(start + i - 1) % n + 1]
        local header
        if token then
            -- 登录 token 走 Authorization 头。放进 URL query 会被访问日志、
            -- 代理日志、Referer 和浏览器历史一路抄送
            header = { authorization = "Bearer " .. token }
        end
        local data
        if body then
            header = header or {}
            header["content-type"] = "application/json"
            data = cjson.encode(body)
        end
        -- 连接失败时 httpc.request 抛错而不是返回状态码，SDK 要能换一台继续试
        local ok, status, res = pcall(httpc.request, method, host, url, nil, header, data)
        if ok and status == 200 then
            return cjson.decode(res) or res
        end
        log.warn(
            "account request failed",
            "method",
            method,
            "url",
            url,
            "host",
            host,
            "status",
            ok and status or nil,
            "err",
            ok and nil or status
        )
    end
    return nil
end

local function ok_result(res)
    return type(res) == "table" and res.code == errcode.OK
end

-- 开发登录：POST /dev_login 按账号名直接签发 token，不校验任何身份，
-- 只供本地开发和机器人使用，正式环境必须关掉（见 docs/guide/login.md）。
-- 正式客户端的 token 由平台登录服务签发，拿到后直接用下面的接口即可
function Account:dev_login(name)
    local res = self:request("POST", "/dev_login", nil, { account = name })
    if not ok_result(res) then
        log.error("dev_login failed", "res", res)
        return nil
    end
    -- token 是登录凭据，只能记录长度这类非敏感信息
    log.info("got login token", "len", #res.token)
    return res.token
end

-- 服务器列表（免登录）。最新开放的服带 recommended = true。
-- 成功返回列表（可能为空），失败返回 nil
function Account:servers()
    local res = self:request("GET", "/servers")
    if not ok_result(res) then
        log.error("failed to get servers", "res", res)
        return nil
    end
    return res.servers
end

-- 挑一个服：recommended 优先，没有则取列表第一个。
-- 建角只能选 status = "open" 的服；角色只记出生服，登录时报的 server 必须是出生服
function Account:pick_recommended_server()
    local servers = self:servers()
    if not servers then
        return nil
    end
    for _, entry in ipairs(servers) do
        if entry.recommended then
            return entry.server
        end
    end
    return servers[1] and servers[1].server
end

-- 角色列表（带 Bearer token）。成功返回列表（可能为空），失败返回 nil
function Account:roles(token)
    local res = self:request("GET", "/roles", token)
    if not ok_result(res) then
        log.error("failed to get roles", "res", res)
        return nil
    end
    return res.roles
end

-- 建角。成功返回角色表，失败返回 nil
function Account:create_role(token, server, name)
    local res = self:request("POST", "/create_role", token, { server = server, name = name })
    if not ok_result(res) then
        log.error("failed to create role", "res", res)
        return nil
    end
    return res.role
end

-- 有角色取第一个，没有则在指定服建一个
function Account:ensure_role(token, name, server)
    local roles = self:roles(token)
    if not roles then
        return nil
    end
    if roles[1] then
        return roles[1]
    end
    return self:create_role(token, server, name)
end

-- 在线网关列表（免登录）。网关地址不写死在客户端配置里：网关键挂在节点租约上，
-- 列表里只会有真的在线的网关，客户端自己挑一台连，连不上换下一台
-- （见 docs/guide/client_protocol.md 第 1 节）。成功返回列表，失败返回 nil
function Account:gates()
    local res = self:request("GET", "/gates")
    if not ok_result(res) then
        log.error("failed to get gates", "res", res)
        return nil
    end
    return res.gates
end

return M

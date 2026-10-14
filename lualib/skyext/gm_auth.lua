-- GM 鉴权与授权：把"谁在操作"和"这条指令有多危险"分开。
--
-- 原来所有人共用一个 gm_auth_token：拿到它的人既能看服务列表，也能 kill 服务、
-- inject 代码、用 getenv 读出登录密钥，出了事还查不出是谁干的。这里改成一人一个
-- token，账号挂一个角色，角色给出能执行到哪一级指令。
local config = require "skyext.config"
local secret = require "skyext.secret"
local log = require "skyext.log"

local M = {}

-- 指令危险等级：
--   read  只读查询，看不出手脚
--   write 改运行时状态但不碰代码和进程（gc、重载配置、重放死信）
--   admin 能拿到进程控制权或机密（kill、inject、setenv、getenv、热更）
M.LEVELS = { read = 1, write = 2, admin = 3 }
-- 注册指令时没写 level 就按 admin 算：漏标的新指令应该是最难执行到的那一类，
-- 而不是谁都能跑。
M.DEFAULT_LEVEL = "admin"

local BUILTIN_ROLES = {
    readonly = "read",
    operator = "write",
    admin = "admin",
}

-- 内部调用（服务自己触发 GM 指令）没有账号，按系统身份放行，但一样进审计
M.SYSTEM = { name = "system", role = "system", level = M.LEVELS.admin }

-- nil 表示还没加载，false 表示加载过但一个可用账号都没有
local g_accounts

function M.normalize_level(level, cmd_name)
    if level == nil then
        return M.DEFAULT_LEVEL
    end
    if M.LEVELS[level] then
        return level
    end
    log.error("GM command has an unknown level, treated as admin", "cmd", cmd_name, "level", tostring(level))
    return M.DEFAULT_LEVEL
end

local function build_roles()
    local roles = {}
    for name, level in pairs(BUILTIN_ROLES) do
        roles[name] = { level = M.LEVELS[level], extra = {} }
    end

    local custom = config.get_table("gm_roles")
    if type(custom) ~= "table" then
        return roles
    end
    for name, def in pairs(custom) do
        local level = type(def) == "table" and M.LEVELS[def.level]
        if not level then
            log.error("GM role has no valid level, ignored", "role", tostring(name))
        else
            -- extra 只能加不能减：角色定义写错时最坏是少给权限，不会多给
            local extra = {}
            for _, cmd in ipairs(def.extra or {}) do
                extra[cmd] = true
            end
            roles[name] = { level = level, extra = extra }
        end
    end
    return roles
end

local function load_accounts()
    local list = config.get_table("gm_accounts")
    if type(list) ~= "table" or #list == 0 then
        log.error("no GM account configured, GM interface is disabled")
        return false
    end

    local roles = build_roles()
    local accounts = {}
    local seen_name, seen_token = {}, {}
    for i, def in ipairs(list) do
        local name = type(def) == "table" and def.name or nil
        local where = type(name) == "string" and name or ("#" .. i)
        local role = roles[type(def) == "table" and def.role]
        -- GM token 不走 allow_insecure_secret：登录密钥弱了是本地开发的事，
        -- GM 弱了是整个进程的事
        local token_ok, token_reason = secret.check(type(def) == "table" and def.token or nil)
        if type(name) ~= "string" or name == "" then
            log.error("GM account has no name, ignored", "index", i)
        elseif seen_name[name] then
            log.error("GM account name is duplicated, ignored", "account", name)
        elseif not role then
            log.error("GM account has an unknown role, ignored", "account", where, "role", tostring(def.role))
        elseif not token_ok then
            log.error("GM account token is unusable, ignored", "account", where, "reason", token_reason)
        elseif seen_token[def.token] then
            log.error("GM account token is shared with another account, ignored", "account", where)
        else
            seen_name[name] = true
            seen_token[def.token] = true
            accounts[#accounts + 1] = {
                name = name,
                role = def.role,
                level = role.level,
                extra = role.extra,
                token = def.token,
            }
        end
    end

    if #accounts == 0 then
        log.error("no usable GM account, GM interface is disabled")
        return false
    end
    log.info("GM accounts loaded", "count", #accounts)
    return accounts
end

local function get_accounts()
    if g_accounts == nil then
        g_accounts = load_accounts()
    end
    return g_accounts
end

-- 重新读配置。GM 账号是进程启动时定下的，这里给测试和将来的重载指令留入口。
function M.reload()
    g_accounts = nil
end

-- 定长比较：逐字节比完再判等，不让对方从"第几个字节开始不一样"里试出 token。
-- 长度本来就能从别的地方观察到，不同长度直接判否。
local function secure_equal(a, b)
    if #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = diff | (string.byte(a, i) ~ string.byte(b, i))
    end
    return diff == 0
end

-- @return account 或 nil, reason
function M.authenticate(token)
    local accounts = get_accounts()
    if not accounts then
        return nil, "no usable GM account configured"
    end
    if type(token) ~= "string" or token == "" then
        return nil, "missing token"
    end
    local matched
    for i = 1, #accounts do
        -- 不提前 break：匹配到第几个账号也是信息
        if secure_equal(accounts[i].token, token) then
            matched = accounts[i]
        end
    end
    if not matched then
        return nil, "invalid token"
    end
    return matched
end

-- @return true 或 false, reason
function M.authorize(account, cmd_name, cmd_level)
    local need = M.LEVELS[cmd_level] or M.LEVELS[M.DEFAULT_LEVEL]
    if account.level >= need then
        return true
    end
    if account.extra and account.extra[cmd_name] then
        return true
    end
    return false,
        string.format("role '%s' is not allowed to run '%s' (%s)", account.role, cmd_name, cmd_level or M.DEFAULT_LEVEL)
end

return M

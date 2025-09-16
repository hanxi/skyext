-- path config
root = "./"

luaservice = root .. "service/?.lua;"
luaservice = luaservice .. root .. "service/?/main.lua;"
luaservice = luaservice .. root .. "skynet/service/?.lua;"

lua_path = root .. "?.lua;"
lua_path = lua_path .. root .. "lualib/?.lua;"
lua_path = lua_path .. root .. "lualib/?/init.lua;"
lua_path = lua_path .. root .. "skynet/lualib/?.lua;"

lua_cpath = root .. "luaclib/?.so;"
lua_cpath = lua_cpath .. root .. "skynet/luaclib/?.so;"

cpath = root .. "skynet/cservice/?.so;"
snax = root .. "service/?.lua;"

lualoader = root .. "lualib/loader.lua"
preload = root .. "lualib/preload.lua"

-- core config
thread = 8
bootstrap = "snlua bootstrap" -- The service for bootstrap
harbor = 0 -- disable master-slave mode

-- log config
logger = "logger"
logservice = "snlua"
bootfaillogpath = "logs/bootfail.log" -- 启动失败的日志文件
log_overload_mqlen = 1000000 -- 日志过载队列长度
log_src = true -- 日志是否打印代码位置
log_print_table = true -- 日志是否打印table内容
log_level = 4 -- 日志等级 DEBUG = 4, INFO = 3, WARN = 2, ERROR = 1, FATAL = 0
log_config = log_config or [[
{
    {
        name = "file",
        filename = "logs/skyext.log",
        split = "size", -- size/line/day/hour
        maxline = 10000, -- 每个文件最大行数 line split 有效
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    }
}
]]

etcd_config = [[
{
    http_host = {
        "http://127.0.0.1:2378",
        "http://127.0.0.1:2379",
        "http://127.0.0.1:2377",
    },
    user = "root",
    password = "123456",
}
]]

mongo_config = [[
{
    center = {
        connections = 4, -- 连接数
        cfg = {
            host = "127.0.0.1",
            port = 27017,
            username = nil,
            password = nil,
            authdb = nil,
        },
        collections = {
            gid = {
                indexes = {
                    { "name", unique = true, background = true },
                },
            },
            user = {
                indexes = {
                    { "account", unique = true, background = true },
                },
            },
        },
    },
    game = {
        connections = 4, -- 连接数
        cfg = {
            host = "127.0.0.1",
            port = 27017,
            username = nil,
            password = nil,
            authdb = nil,
        },
        collections = {
            role = {
                indexes = {
                    { "rid", unique = true, background = true },
                    { "account", background = true },
                },
            },
        },
    },
}
]]

-- other config
sproto_index = 1
sproto_schema_path = "build/proto/sproto.spb"

-- 最大角色数量
max_role_count = 5

user_db_name = "center"
user_db_coll = "user"

role_db_name = "game"
role_db_coll = "role"

-- log config
bootfaillogpath = "logs/bootfail.log" -- 启动失败的日志文件
log_overload_mqlen = 1000000 -- 日志过载队列长度
log_src = true -- 日志是否打印代码位置
log_print_table = true -- 日志是否打印table内容
log_level = 4 -- 日志等级 DEBUG = 4, INFO = 3, WARN = 2, ERROR = 1, FATAL = 0
log_config = log_config
    or {
        {
            name = "file",
            filename = "logs/skyext.log",
            split = "size", -- size/line/day/hour
            maxline = 10000, -- 每个文件最大行数 line split 有效
            maxsize = "100M", -- 每个文件最大尺寸 size split 有效
        },
        {
            name = "console",
        },
    }

etcd_config = {
    http_host = {
        "http://127.0.0.1:2379",
        "http://127.0.0.1:2378",
        "http://127.0.0.1:2377",
    },
    --user = "root",
    --password = "123456",
}

mongo_config = {
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
    role = {
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
                    { "account", "server", background = true },
                },
            },
        },
    },
}

-- other config
sproto_index = 1
sproto_schema_path = "build/proto/sproto.spb"
proto_checksum_enable = true -- 是否检查 proto 协议

-- 最大角色数量
max_role_count = 5

user_db_name = "center"
user_db_coll = "user"

role_db_name = "role"
role_db_coll = "role"

db_save_interval = 3 * 60 -- 数据入库间隔秒

login_jwt_secret = "your_access_secret" -- 登录用的 jwt 密钥

-- 客户端看到到服务器与游戏服的映射
server2game = {
    ["s1"] = "game1",
    ["s2"] = "game2",
    ["s3"] = "game2", -- game3 合并到 game2 之后
}

http_request_body_size = 1024 * 1024

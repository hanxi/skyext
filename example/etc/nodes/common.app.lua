-- log config
bootfaillogpath = "logs/bootfail.log" -- 启动失败的日志文件
log_overload_mqlen = 1000000 -- 日志过载队列长度
log_src = true -- 日志是否打印代码位置
log_print_table = true -- 日志是否打印table内容
log_level = 3 -- 日志等级 DEBUG = 4, INFO = 3, WARN = 2, ERROR = 1, FATAL = 0（DEBUG 会打出每次 DB 读写，仅本地排查时开）
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
    entity = {
        connections = 4,
        cfg = {
            host = "127.0.0.1",
            port = 27017,
            username = nil,
            password = nil,
            authdb = nil,
        },
        collections = {
            entity_msg = {
                indexes = {
                    -- pending 消息按 seq 升序分页读取，seq 必须在索引末尾
                    { "target_type", "target_id", "status", "seq", background = true },
                    { "msg_id", unique = true, background = true },
                    {
                        "create_time",
                        expireAfterSeconds = 604800,
                        partialFilterExpression = { status = 1 },
                        background = true,
                    },
                    -- 死信队列按入列时间列出，status 放前缀上，不依赖 target 过滤
                    { "status", "dead_time", background = true },
                },
            },
        },
    },
}

-- 同一条可靠消息连续投递失败多少次后转入死信队列。
-- 只有“错在消息本身”的失败才计数（没有对应 handler、handler 抛错）；
-- 租约失效、落库失败这类环境问题不计，否则一次数据库抖动就会误伤正常消息。
-- 死信用 GM 指令 dlq_list / dlq_replay / dlq_discard 处理。
reliable_msg_max_attempts = 5

-- Entity 系统配置
entity_types = {
    role = {
        db_name = "role",
        db_coll = "role",
        id_field = "rid",
        schema = "role",
        agent_count = 2,
        unload_delay = 300,
        -- 兜底节点列表：正常情况下实体落在哪个节点由服务发现报告的存活节点决定
        -- （entity_agentmgr 注册的 "entity:role"），这里只在服务发现不可用时生效
        nodes = { "rolenode1", "rolenode2" },
        client_enabled = true,
        modules_path = "modules",
    },
}

res_path = "example/res"
res_lazy_path = "example/res/lazy"

-- other config
sproto_index = 1
sproto_schema_path = "example/build/proto/sproto.spb"
proto_checksum_enable = true -- 是否检查 proto 协议

-- 最大角色数量
max_role_count = 5

user_db_name = "center"
user_db_coll = "user"

role_db_name = "role"
role_db_coll = "role"

db_save_interval = 3 * 60 -- 数据入库间隔秒

-- 登录用的 jwt 密钥。下面这个示例值是公开的，谁都能拿它伪造登录态，
-- 部署前必须换成随机长串（例如 openssl rand -hex 32），且不少于 16 字符。
login_jwt_secret = "your_access_secret"
-- 仅供本地开发：显式打开后允许继续使用弱密钥（日志里会持续告警）。
-- 生产环境不要设置这一项——弱密钥会直接导致登录被拒绝。
allow_insecure_secret = true

-- 客户端看到到服务器与游戏服的映射
server2game = {
    ["s1"] = "game1",
    ["s2"] = "game2",
    ["s3"] = "game2", -- game3 合并到 game2 之后
}

-- HTTP 服务端资源上限（节点级默认值，单个 http_server 实例可在 start 的 conf 里覆盖）。
-- 这些值回答的是"单个客户端能不能把节点拖垮"，所以取保守侧。
http_max_connections = 1024 -- 同时在处理的连接数上限，超出的新连接直接关闭
http_read_timeout = 10 -- 读完一个完整请求的总时限（秒），绝对时限，不随收包续期
http_write_timeout = 10 -- 写出一个响应的时限（秒）
http_keepalive_timeout = 60 -- keep-alive 空闲时限（秒），0 表示关闭 keep-alive
http_keepalive_requests = 100 -- 单条连接最多服务多少个请求
http_request_body_size = 1024 * 1024 -- 请求 body 字节上限，超过返回 413

-- GM 鉴权 token，部署时替换为随机长串（不少于 16 字符）；
-- 未配置或仍是占位符时 /gm/execute 接口禁用
gm_auth_token = "CHANGE_ME_TO_RANDOM_TOKEN"

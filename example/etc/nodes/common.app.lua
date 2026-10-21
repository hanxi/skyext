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
            -- 角色名在出生服内唯一：合服、跨服都不会撞名，跨服场景显示成 [S3]张三
            role_name = {
                indexes = {
                    { "server", "name", unique = true, background = true },
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
            rank = {
                indexes = {
                    -- rank 类型开了 auto_create，首次加载时靠唯一索引防止并发建出两份
                    { "rank_id", unique = true, background = true },
                },
            },
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
        -- 离线（没有客户端绑定）多久卸载，单位秒
        unload_delay = 300,
        -- 角色文档由 Account 建角时创建，按 rid 加载时文档不存在就是 rid 错了，不能凭空建一份
        auto_create = false,
        -- 兜底节点列表：正常情况下实体落在哪个节点由服务发现报告的存活节点决定
        -- （entity_agentmgr 注册的 "entity:role"），这里只在服务发现不可用时生效
        nodes = { "rolenode1", "rolenode2" },
        client_enabled = true,
        modules_path = "modules",
    },
    -- 排行榜：每个 game 一份的全局单例，做成常驻实体
    rank = {
        db_name = "entity",
        db_coll = "rank",
        id_field = "rank_id",
        schema = "rank",
        agent_count = 1,
        -- 不因闲置卸载，只在停服、失租时离开内存
        resident = true,
        -- 第一次加载时文档还不存在，由实体系统按 ID 建出来
        auto_create = true,
        -- 每个 game 一份：按区服目录里的 game 自动预加载，开服后新 game 的排行榜自动出现。
        -- 用 router.scoped_call("rank", game, ...) 访问
        scope = "game",
        nodes = { "rolenode1", "rolenode2" },
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

mail_max_count = 100 -- 单个角色邮箱上限，满了丢最早的一封

-- snowflake 机器号默认由各节点启动时从 etcd 抢一个带租约的槽位，扩容不用改配置。
-- 只有需要把某个节点的号钉死时才在节点配置里写 snowflake_machine_id。

-- 登录用的 jwt 密钥。下面这个示例值是公开的，谁都能拿它伪造登录态，
-- 部署前必须换成随机长串（例如 openssl rand -hex 32），且不少于 16 字符。
login_jwt_secret = "your_access_secret"
-- 仅供本地开发：显式打开后允许继续使用弱密钥（日志里会持续告警）。
-- 生产环境不要设置这一项——弱密钥会直接导致登录被拒绝。
allow_insecure_secret = true

-- 开发用登录接口 POST /dev_login：按账号名直接签发 token，不校验身份，robot 靠它登录。
-- 正式环境的 token 由 SDK/平台登录服务签发，这一项必须去掉。
dev_login_enable = true

-- 登录 token 的签发方与接收方。签名密钥只保证"是我们签的"，这两项进一步保证
-- "是这套服务签的、是签给这套服务的"：密钥被别的系统或别的用途复用时不会互相串。
login_jwt_issuer = "skyext"
login_jwt_audience = "skyext-game"
login_jwt_ttl = 300 -- 登录 token 有效期秒数，拿到就用，不需要长
login_jwt_leeway = 30 -- 允许的节点间时钟差秒数，给大了等于延长 token 寿命

-- 区服目录的种子。区服目录（server -> game -> zone）存在 etcd 里，由 GM 命令 realm_open /
-- realm_set_zone 维护，开服、调战区都不用改配置、不用重启。只有目录完全为空时（本地开发、
-- 新环境首次启动）才会把这里的内容写进去，之后改这份配置不再生效。
realm_seed = {
    zones = {
        zone1 = {},
    },
    games = {
        game1 = { zone = "zone1" },
        game2 = { zone = "zone1" },
    },
    servers = {
        s1 = { game = "game1", name = "一区", tag = "S1" },
        s2 = { game = "game2", name = "二区", tag = "S2" },
        s3 = { game = "game2", name = "三区", tag = "S3" }, -- 三区合入 game2：两个区的玩家在一起玩
    },
}

-- HTTP 服务端资源上限（节点级默认值，单个 http_server 实例可在 start 的 conf 里覆盖）。
-- 这些值回答的是"单个客户端能不能把节点拖垮"，所以取保守侧。
http_max_connections = 1024 -- 同时在处理的连接数上限，超出的新连接直接关闭
http_read_timeout = 10 -- 读完一个完整请求的总时限（秒），绝对时限，不随收包续期
http_write_timeout = 10 -- 写出一个响应的时限（秒）
http_keepalive_timeout = 60 -- keep-alive 空闲时限（秒），0 表示关闭 keep-alive
http_keepalive_requests = 100 -- 单条连接最多服务多少个请求
http_request_body_size = 1024 * 1024 -- 请求 body 字节上限，超过返回 413

-- GM 接口的 token。这是管理员接口：kill、inject、setenv、热更都在里面，
-- 拿到 token 就等于拿到进程控制权，所以不分级，要分人分权请由对接它的后台去做。
-- 部署时用 openssl rand -hex 32 现生成，不少于 16 字符且不能是占位符；
-- 没配可用 token 时 /gm/* 全部拒绝（allow_insecure_secret 对 GM 无效）。
-- 示例里默认不配，所以 GM 接口是关着的，本地要用就在这里填一个。
-- gm_auth_token = "..."

-- 指标抓取端点。和 GM 一样默认只听回环：这个端点不鉴权，暴露出去等于把内部
-- 拓扑和业务量公开。线上让 Prometheus 从同机或内网侧抓。
-- 端口按节点配（见各 *.app.lua 的 metrics_http_port），同机跑多个节点才不会撞。
metrics_http_host = "127.0.0.1"
metrics_scrape_timeout = 300 -- 单次抓取等各服务回包的时限（1/100 秒），卡住的服务不拖垮整次抓取

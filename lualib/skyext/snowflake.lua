local function snowflake_service()
    local log = require "skyext.log"
    local skynet = require "skynet"
    local cmd_api = require "skyext.cmd_api"
    local config = require "skyext.config"
    local machine_id = require "skyext.machine_id"
    local node_shutdown_api = require "skyext.node_shutdown_api"

    local function parse_date(str_date)
        local pattern = "(%d+)-(%d+)-(%d+)"
        local y, m, d = str_date:match(pattern)
        if not y or not m or not d then
            error("invalid date format")
        end
        return os.time({ year = y, month = m, day = d, hour = 0 })
    end

    -- 时间起点
    local start_date = config.get("snowflake_start_date") or "2025-10-09"
    local BEGIN_TIMESTAMP = parse_date(start_date)

    -- 每一部分占用的位数 (总共 1 + 63 = 64 位，符号位为0)
    local TIME_BIT = 32 -- 秒级时间戳，136年
    local MACHINE_BIT = 8 -- 256个进程
    local SEQUENCE_BIT = 13 -- 8192/秒；id_generator 按千批量预取，要给多服务冷启动同时 refill 留余量
    -- 位数检查。MACHINE_BIT + SEQUENCE_BIT <= 21 是硬约束：ID 最大值 = (2^32-1)<<21 +
    -- (2^21-1) = 2^53-1，恰好不超过 JS 的 Number.MAX_SAFE_INTEGER。浏览器客户端
    -- （phaser-game 这类）从 JSON.parse 到 sproto 编码全程用 double 传递 rid，一旦
    -- 超过 2^53 就会精度丢失，登录时上报的 rid 与库里对不上（ROLE_NOT_EXIST）。
    assert(MACHINE_BIT + SEQUENCE_BIT <= 21, "id exceeds JS Number.MAX_SAFE_INTEGER")
    assert(TIME_BIT + MACHINE_BIT + SEQUENCE_BIT < 64, "total bits exceeds 64")

    -- 每一部分的最大值
    local MAX_SEQUENCE = (1 << SEQUENCE_BIT) - 1
    local MAX_MACHINE_ID = (1 << MACHINE_BIT) - 1
    local MAX_RELATIVE_TIME = (1 << TIME_BIT) - 1

    -- 每一部分向左的位移
    local MACHINE_LEFT = SEQUENCE_BIT
    local TIMESTAMP_LEFT = SEQUENCE_BIT + MACHINE_BIT

    -- 机器号要么写死在配置里，要么从 etcd 抢一个带租约的槽位
    local FIXED_MACHINE_ID
    local machine_slot
    local sequence = 0
    local last_timestamp = -1

    local function current_machine_id()
        return FIXED_MACHINE_ID or machine_slot.id
    end

    -- 号不在手上就绝不能发 ID：接手这个号的进程可能正在用同一个 (时间, 机器号)
    local function machine_id_held()
        return FIXED_MACHINE_ID ~= nil or (machine_slot ~= nil and machine_slot:valid())
    end

    -- 启动时 id_generator 会立刻来预取一批号，而抢号要等 etcd 回话（通常几毫秒）。
    -- 这段时间里的请求等号到手再发；等太久说明 etcd 不可用，报错让调用方知道，不无限卡住
    local MACHINE_ID_WAIT_TICKS = 300
    local function wait_machine_id()
        local waited = 0
        while not machine_id_held() do
            if waited >= MACHINE_ID_WAIT_TICKS then
                error("snowflake machine id is not held")
            end
            skynet.sleep(10)
            waited = waited + 10
        end
    end

    -- 获取当前时间，单位 1s
    local function get_cur_timestamp()
        return math.floor(skynet.time())
    end

    local function generate_one()
        local cur_timestamp = get_cur_timestamp()
        -- 检查时钟回拨
        if cur_timestamp < last_timestamp then
            error("clock moved backwards")
        end

        if cur_timestamp == last_timestamp then
            sequence = sequence + 1
            if sequence > MAX_SEQUENCE then
                log.warn("sequence overflow", "sequence", sequence, "cur_timestamp", cur_timestamp)
                -- 等待下一个时间单位
                repeat
                    skynet.sleep(50) -- sleep 0.5s
                    cur_timestamp = get_cur_timestamp()
                until cur_timestamp > last_timestamp
                sequence = 0
            end
        else
            -- 新的时间单位，序列号重置
            sequence = 0
        end

        last_timestamp = cur_timestamp
        local relative_timestamp = cur_timestamp - BEGIN_TIMESTAMP
        -- 修复: 检查相对时间戳是否溢出
        assert(relative_timestamp <= MAX_RELATIVE_TIME, "timestamp is out of range, over 174 years")

        -- 组合 ID
        return (relative_timestamp << TIMESTAMP_LEFT) | (current_machine_id() << MACHINE_LEFT) | sequence
    end

    local CMD = {}

    -- 停服的 release 阶段调用：实体都已落库、不会再要号了，归还机器号，
    -- 同一个节点马上重启能拿回原来的号
    function CMD.shutdown()
        if machine_slot then
            return machine_slot:release()
        end
        return true
    end

    function CMD.newid()
        wait_machine_id()
        return generate_one()
    end

    -- 返回一个顺序数组 { id1, id2, ... }
    function CMD.newids(count)
        wait_machine_id()

        count = tonumber(count) or 1
        if count < 1 then
            count = 1
        end
        if count > 10000 then -- 可根据业务场景修改
            error("count is too large")
        end

        local list = {}
        for i = 1, count do
            list[i] = generate_one()
        end
        return list
    end

    skynet.start(function()
        -- 配置写死的编号优先：运维需要把某个节点的号钉死时仍然走得通
        FIXED_MACHINE_ID = config.get_number("snowflake_machine_id")
        if FIXED_MACHINE_ID then
            assert(
                FIXED_MACHINE_ID >= 0 and FIXED_MACHINE_ID <= MAX_MACHINE_ID,
                "invalid machine_id = " .. tostring(FIXED_MACHINE_ID)
            )
        else
            machine_slot = machine_id.new("snowflake", MAX_MACHINE_ID + 1)
        end

        -- 初始化 last_timestamp，避免首次启动时钟回拨误判
        last_timestamp = get_cur_timestamp()
        log.info(
            "snowflake service started",
            "machine_id",
            FIXED_MACHINE_ID or "auto",
            "begin_timestamp",
            BEGIN_TIMESTAMP,
            "last_timestamp",
            last_timestamp
        )

        -- 先开始收消息再去抢号：etcd 还没就绪时启动不会卡住，发号请求等一会儿拿不到号就报错
        cmd_api.dispatch(CMD)
        if machine_slot then
            skynet.fork(function()
                machine_slot:acquire()
            end)
            -- 写死的号不需要归还
            skynet.fork(function()
                node_shutdown_api.add_hook("release", "shutdown")
            end)
        end
    end)
end

local service = require "skynet.service"
local skynet = require "skynet"

local M = {}

local snowflake_service_addr = nil
skynet.init(function()
    snowflake_service_addr = service.new("snowflake", snowflake_service)
end)

function M.newid()
    return skynet.call(snowflake_service_addr, "lua", "newid")
end

-- 批量获取ID接口
function M.newids(count)
    return skynet.call(snowflake_service_addr, "lua", "newids", count)
end

return M

local mongo_conn = require "skyext.mongo_conn"
local id_generator = require "skyext.id_generator"
local log = require "skyext.log"
local time = require "skyext.time"

local M = {}

local DB_NAME = "entity"
local DB_COLL = "entity_msg"

local function get_coll()
    return mongo_conn.get_collection(DB_NAME, DB_COLL)
end

function M.save(target_type, target_id, cmd, args)
    local msg_id = id_generator.newid()
    local doc = {
        msg_id = msg_id,
        target_type = target_type,
        target_id = target_id,
        cmd = cmd,
        args = args,
        status = 0,
        create_time = time.now(),
    }
    local coll = get_coll()
    coll:safe_insert(doc)
    log.debug("reliable_msg save", "msg_id", msg_id, "target_type", target_type, "target_id", target_id, "cmd", cmd)
    return msg_id
end

function M.load_pending(target_type, target_id)
    local coll = get_coll()
    local cursor = coll:find({
        target_type = target_type,
        target_id = target_id,
        status = 0,
    }, { sort = { msg_id = 1 } })
    local result = {}
    while cursor:hasNext() do
        result[#result + 1] = cursor:next()
    end
    return result
end

function M.mark_delivered(msg_id)
    local coll = get_coll()
    coll:findAndModify({
        query = { msg_id = msg_id },
        update = { ["$set"] = { status = 1 } },
    })
end

return M

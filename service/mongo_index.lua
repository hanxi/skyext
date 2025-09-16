local skynet = require "skynet"
local mongo = require "skynet.db.mongo"
local config = require "config"
local cmd_api = require "cmd_api"
local log = require "log"

local CMD = {}

local mongo_config = config.get_table("mongo_config")

function CMD.create_indexes()
    local all_ok = true
    for dbname, db_config in pairs(mongo_config) do
        local dbs = mongo.client(db_config.cfg)
        local db = dbs[dbname]
        for coll_name, coll_config in pairs(db_config.collections) do
            local collection = db[coll_name]
            if collection then
                for _, index in ipairs(coll_config.indexes or {}) do
                    local ok, err = pcall(collection.createIndex, collection, index)
                    if not ok then
                        log.error("failed to create index", "dbname", dbname, "coll_name", coll_name, "err", err)
                        all_ok = false
                    else
                        log.info("index created successfully", "dbname", dbname, "coll_name", coll_name, "index", index)
                    end
                end
            else
                log.error("collection not found", "dbname", dbname, "coll_name", coll_name)
                all_ok = false
            end
        end
    end
    return all_ok
end

skynet.start(function()
    cmd_api.dispatch(CMD)
end)

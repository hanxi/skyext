-- 实体放置：把 cluster_discovery 报告的存活节点接到实体路由上。
--
-- 选节点用 rendezvous hashing（HRW），不用 jump consistent hash：
--   * jchash 的输入是桶下标，只有在列表尾部增删节点时才保证最小迁移；从中间
--     摘掉一个节点会把几乎所有实体重排。路由一旦跟着集群成员走，这不可接受。
--   * jchash 还要求节点列表顺序稳定，而存活集合是从哈希表遍历出来的，顺序本
--     来就不定。
-- HRW 对每个 (实体, 节点) 算分取最大值：节点进出只影响它自己那一份，且结果与
-- 列表顺序无关，正好是成员驱动路由需要的性质。
local log = require "skyext.log"

local M = {}

local SERVICE_PREFIX = "entity:"

-- discovery 客户端在 require 时注册 skynet.init 去创建 uniqueservice，加载期拉
-- 进来会把这个依赖扩散到每个 require entity.types 的服务，因此惰性取
local g_discovery
local function discovery()
    if not g_discovery then
        g_discovery = require "skyext.cluster_discovery"
    end
    return g_discovery
end

-- 实体类型在服务发现里的服务名，entity_agentmgr 就是用它注册的
function M.service_name(type_name)
    return SERVICE_PREFIX .. type_name
end

local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME = 0x100000001b3
local GOLDEN = 0x9e3779b97f4a7c15

local g_node_seed = {}

local function node_seed(node)
    local seed = g_node_seed[node]
    if not seed then
        seed = FNV_OFFSET
        for i = 1, #node do
            seed = (seed ~ string.byte(node, i)) * FNV_PRIME
        end
        g_node_seed[node] = seed
    end
    return seed
end

-- splitmix64 的收尾混合，雪崩性足够好；少了它相邻 entity_id 会在同一节点扎堆
local function mix64(x)
    x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
    x = (x ~ (x >> 27)) * 0x94d049bb133111eb
    x = x ~ (x >> 31)
    return x & 0x7fffffffffffffff
end

function M.score(node, entity_id)
    return mix64(node_seed(node) ~ (entity_id * GOLDEN))
end

-- 节点内选 agent 用。snowflake ID 的低位是每秒归零的序号，直接取模会让
-- 低频发号（比如建角）全挤进同一个 agent，所以先打散再取模
function M.hash(entity_id)
    return mix64(entity_id * GOLDEN)
end

-- 候选为空时返回 nil。分数相同按节点名取小的那个，保证各节点算出同一个结果
function M.select(nodes, entity_id)
    local best, best_score
    for i = 1, #nodes do
        local node = nodes[i]
        local score = M.score(node, entity_id)
        if best == nil or score > best_score or (score == best_score and node < best) then
            best, best_score = node, score
        end
    end
    return best
end

local function live_nodes(type_name)
    local ok, nodes = pcall(function()
        return discovery().nodes(M.service_name(type_name))
    end)
    if not ok then
        return nil, nodes
    end
    return nodes
end

-- 兜底状态按类型记一份，避免 discovery 长时间不可用时每次路由都刷一条日志
local g_fallback = {}

function M.calc_node(type_name, type_config, entity_id)
    if math.type(entity_id) ~= "integer" then
        error(string.format("entity id must be an integer: %s", tostring(entity_id)))
    end

    local live, err = live_nodes(type_name)
    local node = live and M.select(live, entity_id)
    if node then
        if g_fallback[type_name] then
            g_fallback[type_name] = nil
            log.info("entity placement back on discovered nodes", "type", type_name, "nodes", live)
        end
        return node
    end

    -- 配置里的 nodes 只是兜底：服务发现才是权威，扩缩容不需要改配置
    local configured = type_config.nodes
    node = configured and M.select(configured, entity_id)
    if not node then
        error(string.format("no available node for entity type: %s", type_name))
    end
    if not g_fallback[type_name] then
        g_fallback[type_name] = true
        log.warn("entity placement fell back to configured nodes", "type", type_name, "err", err, "nodes", configured)
    end
    return node
end

return M

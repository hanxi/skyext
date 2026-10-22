-- skyext 自己的 sproto host。功能和 skynet/lualib/sproto.lua 里的 host 一致，只差一点：
--
-- dispatch 把客户端的 request id（包头 session 字段）当第 5 个返回值交出来。会话层拿它
-- 做上行幂等缓存的键——续接之后客户端会用原 id 重发在途请求，服务端必须认出来直接回
-- 缓存的响应，而不是把扣费抽卡再执行一遍。skynet 的 host 把这个 id 关在 gen_response
-- 的闭包里，返回值第 5 位给的是 ud，外面取不到，只能自己写一份。
--
-- 只用 sproto 的公开接口（queryproto / pack / unpack / encode / decode），不改子模块。
local core = require "sproto.core"
local sproto = require "sproto"

local M = {}

local host = {}
host.__index = host

-- 包头的临时表。decode 填进去之后，到把字段读进局部变量为止没有让出点，复用是安全的；
-- 真正会跨协程存活的只有 req_id，它被 gen_response 捕获成上值。
local header_tmp = {}

local function gen_response(self, response, req_id)
    return function(args)
        header_tmp.type = nil
        header_tmp.session = req_id
        local header = self.sp:encode(self.package, header_tmp)
        if response then
            return core.pack(header .. core.encode(response, args))
        end
        return core.pack(header)
    end
end

function M.new(sp, packagename)
    return setmetatable({
        sp = sp,
        package = packagename or "base.package",
        -- 本端发出的请求：request id -> 等待中的响应类型
        pending = {},
    }, host)
end

-- "REQUEST", 协议名, 请求体, 回包函数, request id（后两个在对端没带 request id 时为 nil）
-- "RESPONSE", request id, 响应体（认不出这个 id 时响应体为 nil，见下）
function host:dispatch(...)
    local bin = core.unpack(...)
    header_tmp.type = nil
    header_tmp.session = nil
    local header, used = self.sp:decode(self.package, bin, header_tmp)
    local msg_type, req_id = header.type, header.session
    local content = bin:sub(used + 1)
    if msg_type then
        local proto = sproto.queryproto(self.sp, msg_type)
        local request
        if proto.request then
            request = core.decode(proto.request, content)
        end
        if req_id then
            return "REQUEST", proto.name, request, gen_response(self, proto.response, req_id), req_id
        end
        return "REQUEST", proto.name, request
    end
    local response = self.pending[req_id]
    if not response then
        -- 认不出的 request id。不能抛：续接之后同一个请求可能有两份响应在路上（重放出来
        -- 的那份，和按原 id 重发后命中幂等缓存的那份），第二份到达时这张表已经清了。
        -- 抛错会让调用方连"收到过一个包"都不知道，下行计数当场失同步。
        -- 响应体解不出来——类型信息就在这张表里——所以只交出 id，由调用方计数后丢弃
        return "RESPONSE", req_id
    end
    self.pending[req_id] = nil
    if response == true then
        return "RESPONSE", req_id
    end
    return "RESPONSE", req_id, core.decode(response, content)
end

-- 返回打包函数 (name, args, req_id) -> 字节。带 req_id 时登记等待响应
function host:attach()
    return function(name, args, req_id)
        local sp = self.sp
        local proto = sproto.queryproto(sp, name)
        header_tmp.type = proto.tag
        header_tmp.session = req_id
        local header = sp:encode(self.package, header_tmp)
        if req_id then
            self.pending[req_id] = proto.response or true
        end
        if proto.request then
            return core.pack(header .. core.encode(proto.request, args))
        end
        return core.pack(header)
    end
end

return M

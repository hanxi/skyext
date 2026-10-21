local global = {}

-- 本节点的 session_gate：登录超时时用它踢掉还没完成登录的连接
global.gate_service = nil

return global

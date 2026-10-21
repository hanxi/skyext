local global = {}

-- 本节点的 session_gate：断开连接（登录超时、登出）走它
global.gate_service = nil

return global

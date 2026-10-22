-- 全局参数表。放在 res/lazy 下，第一次被读到时才 sharetable.query 进来。
-- 真实项目里这类文件由策划的 Excel 导出，不手写。
return {
    ["HitCorrection"] = 1,
    -- 角色名字节上限，建角时校验（example/nodes/account/lualib/account_router.lua）
    ["NameLimit"] = 32,
    -- 新角色的初始道具（example/nodes/role/modules/bag/init.lua）
    ["InitItem"] = {
        { res_type = 101, res_id = 10086, res_size = 1 },
        { res_type = 101, res_id = 10087, res_size = 3 },
    },
    ["InitMission"] = {
        "M101",
        "M102",
    },
}

return {
    desc = "本次热更新的描述",
    checksum = "7dd3064a8baac68d84ff150704a3c51e",
    gitsha_base = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    gitsha_update = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    time = "2026-10-21 12:56:21",
    -- 路径相对于工程根目录（skynet 的 root），与 hotfix_dir 同一基准；
    -- 引擎文件和游戏文件都写在这一套路径下
    update_files = {
        "service/gm.lua",
        "example/lualib/errcode.lua",
    },
    reload_res = true, -- 是否重载策划配置表
    reload_sproto = true, -- 是否重载 sproto 协议
    reload_orm_schema = true, -- 是否重载 orm schema
    clearcache = true, -- 是否 Clear lua code cache
    code_files = {
        "code1.lua", -- 热更代码，一个文件对应一类服务。没有路径，只能是当前目录下的文件
        "code2.lua",
    },
}

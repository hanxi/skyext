return {
    desc = "本次热更新的描述",
    checksum = "01a17cd9a253e3e431d38469a57bed5c",
    gitsha_base = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    gitsha_update = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    time = "2026-01-20 19:11:00",
    update_files = {
        "lualib/cmd_api.lua", -- 路径都是基于工程根目录的相对路径
        "lualib/errcode.lua",
        "service/gm.lua",
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

return {
    desc = "热更示例：示例配表升版本，并在 role 实体 agent 里读出新值",
    checksum = "8af23ad73e9b8975a52ef70f9cb609d9",
    gitsha_base = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    gitsha_update = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    time = "2026-10-23 10:34:13",
    -- 路径相对于工程根目录（skynet 的 root），与 hotfix_dir 同一基准；
    -- 引擎文件和游戏文件都写在这一套路径下
    update_files = {
        "example/res/lazy/hotfix_demo.lua",
    },
    reload_res = true, -- 是否重载策划配置表
    reload_sproto = false, -- 是否重载 sproto 协议
    reload_orm_schema = false, -- 是否重载 orm schema
    clearcache = true, -- 是否 Clear lua code cache（有 code_files 时必须打开）
    code_files = {
        "code1.lua", -- 热更代码，一个文件对应一类服务。没有路径，只能是当前目录下的文件
    },
}

-- ORM schema 基线：上一次确认过的结构，由 ./bin/skyext schema accept 写入。
-- 不要手改；schema check 用它判断新 schema 还能不能读旧文档。
return {
    bag = {
        res = {
            key = "integer",
            type = "map",
            value = "resource",
        },
        res_type = {
            type = "integer",
        },
    },
    mail = {
        attach = {
            type = "mail_attach",
        },
        cfg_id = {
            type = "integer",
        },
        detail = {
            key = "string",
            type = "map",
            value = "string",
        },
        mail_id = {
            type = "integer",
        },
        send_role = {
            type = "mail_role",
        },
        send_time = {
            type = "integer",
        },
        title = {
            key = "string",
            type = "map",
            value = "string",
        },
    },
    mail_attach = {
        res_id = {
            type = "integer",
        },
        res_size = {
            type = "integer",
        },
        res_type = {
            type = "integer",
        },
    },
    mail_role = {
        name = {
            type = "string",
        },
        rid = {
            type = "integer",
        },
    },
    resource = {
        res_id = {
            type = "integer",
        },
        res_size = {
            type = "integer",
        },
    },
    role = {
        _version = {
            type = "integer",
        },
        account = {
            type = "string",
        },
        create_time = {
            type = "integer",
        },
        game = {
            type = "string",
        },
        last_login_time = {
            type = "integer",
        },
        modules = {
            type = "role_modules",
        },
        name = {
            type = "string",
        },
        rid = {
            type = "integer",
        },
        server = {
            type = "string",
        },
    },
    role_bag = {
        bags = {
            key = "integer",
            type = "map",
            value = "bag",
        },
    },
    role_mail = {
        _version = {
            type = "integer",
        },
        mails = {
            key = "integer",
            type = "map",
            value = "mail",
        },
    },
    role_modules = {
        bag = {
            type = "role_bag",
        },
        mail = {
            type = "role_mail",
        },
    },
    str2str = {
        key = {
            type = "string",
        },
        value = {
            type = "string",
        },
    },
}

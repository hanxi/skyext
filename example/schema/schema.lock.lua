-- ORM schema 基线：上一次确认过的结构，由 ./bin/skyext schema accept 写入。
-- 不要手改；schema check 用它判断新 schema 还能不能读旧文档。
--
-- retired 记的是删过的名字。删字段只是不再读它，值一直躺在库里，
-- 所以这些名字不能再用，否则旧值会被当成新值读出来。
return {
    retired = {
        fields = {},
        types = {},
    },
    types = {
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
                item = "mail_attach",
                type = "array",
            },
            content = {
                type = "string",
            },
            mail_id = {
                type = "integer",
            },
            send_time = {
                type = "integer",
            },
            sender = {
                type = "mail_sender",
            },
            title = {
                type = "string",
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
        mail_sender = {
            name = {
                type = "string",
            },
            rid = {
                type = "integer",
            },
        },
        rank = {
            _version = {
                type = "integer",
            },
            entries = {
                key = "integer",
                type = "map",
                value = "rank_entry",
            },
            rank_id = {
                type = "integer",
            },
        },
        rank_entry = {
            name = {
                type = "string",
            },
            rid = {
                type = "integer",
            },
            score = {
                type = "integer",
            },
            time = {
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
            starter_granted = {
                type = "boolean",
            },
        },
        role_mail = {
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
    },
}

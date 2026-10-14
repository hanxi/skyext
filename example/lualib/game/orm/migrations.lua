-- 文档级 schema 迁移链，按集合分组。dbmgr 加载文档时会把缺的步骤按序补上，
-- 并把新版本号写回文档的 _schema_version 字段。详见 docs/guide/orm_migration.md。
--
-- 只能往末尾追加，version 必须等于它在数组里的下标。migrate 拿到的是 mongo 解码出来的
-- 普通表（还没套 orm schema），原地改即可：
--
-- return {
--     role = {
--         {
--             version = 1,
--             desc = "nick 改名为 name",
--             migrate = function(doc)
--                 doc.name = doc.nick or ""
--                 doc.nick = nil
--             end,
--         },
--     },
-- }

return {}

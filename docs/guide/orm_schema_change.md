# 改 ORM schema

玩法代码不需要为 schema 变更写任何迁移脚本。加字段、删字段在运行期是安全的；改名和改类型不安全，由命令行工具在提交前拦下。

## 运行期怎么处理老文档

`dbmgr` 从 MongoDB 读出文档后交给 `orm.decode`，它会把这份文档对齐到当前 schema：

- **schema 里已经没有的字段**：从内存文档里丢掉，打一条 `document has fields the schema no longer declares` 告警。数据库里那份值原样留着，不会被删。
- **文档里缺的新字段**：按类型补零值（`integer`/`number` 补 `0`、`string` 补 `""`、`boolean` 补 `false`、map/array 补 `{}`、结构体递归补）。

补出来的值不算改动，不会因此触发一次回写。所以业务代码读到的永远是完整的当前结构，不用为"这个字段是上个版本才加的"多分一条支路。

自引用的结构没有有限的零值，这种字段会留空（`nil`），读之前要判空。

## 改名和改类型为什么不行

这两种改动在运行期不会报错，只会悄悄丢数据：

- **改名**：旧字段被当成"已删除"丢掉，新字段补零值。玩家的等级就这么归零了。
- **改类型**：`integer` 改成 `string` 之后，旧文档里的数字和新代码的类型检查对不上，写回时才炸，炸在业务代码深处。

要改名或改类型，走加字段的路：先加新字段，让玩法代码同时写新旧两份，确认线上文档都带上新字段之后，再删旧字段。

## 检查工具

```sh
./bin/skyext generate schema   # 先生成
./bin/skyext schema check      # 对比基线
./bin/skyext schema accept     # 确认改动，更新基线
```

基线是 `example/schema/schema.lock.lua`，记录上一次确认过的结构，跟着 `.sproto` 的改动一起提交——评审时直接就能看到 schema 变了什么。

`schema check` 的输出分三级：

| 级别 | 含义 | 退出码 |
| --- | --- | --- |
| `break` | 不兼容：改类型、改 map 的键值类型、改 array 的元素类型 | 1 |
| `warn` | 能跑，但有数据代价：删字段、删结构、疑似改名 | 看是否还有未确认的改动 |
| `info` | 安全：加字段、加结构 | 0 |

同一个结构里同类型的字段一删一加会被识别成疑似改名，单独提示，因为它的数据代价和普通删字段不是一回事。

基线落后于当前 schema 时 `schema check` 也会返回 1，提示执行 `schema accept`。CI 里跑的就是 `schema check`，所以忘了更新基线会在流水线上暴露出来，而不是等上线之后。

确实需要放行不兼容改动（比如这个集合还没有线上数据）时用 `./bin/skyext schema accept --force`。

## 热更

schema 可以热更：GM 命令 `reload_orm_schema` 会重新 require `game.orm.schema`，并把新定义原地替换进进程里那张唯一的 schema 表，已经加载的 ORM 文档继续可读可写可落库。热更同样只适用于加字段、删字段。

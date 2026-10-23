# 改 ORM schema

玩法代码不需要为 schema 变更写任何迁移脚本。加字段、删字段在运行期是安全的；改名和改类型不安全，由命令行工具在提交前拦下。

## 运行期怎么处理老文档

`dbmgr` 从 MongoDB 读出文档后交给 `orm.decode`，它会把这份文档对齐到当前 schema：

- **schema 里已经没有的字段**：从内存文档里丢掉，打一条 `document has fields the schema no longer declares` 告警。数据库里那份值原样留着，不会被删。
- **文档里缺的新字段**：按类型补零值（`integer`/`number` 补 `0`、`string` 补 `""`、`boolean` 补 `false`、map/array 补 `{}`、结构体递归补）。

补出来的值不算改动，不会因此触发一次回写。所以业务代码读到的永远是完整的当前结构，不用为"这个字段是上个版本才加的"多分一条支路。

自引用的结构没有有限的零值，这种字段会留空（`nil`），读之前要判空。

## 删掉的名字不能再用

被丢弃的字段只是不进内存，**值一直留在 MongoDB 里**——`orm` 不会去 `$unset` 它。所以字段名一旦退休就得永久退休：

```
v1  role.create_time : integer      玩家文档里写下了 create_time = 1700000000
v2  删掉 create_time                 内存里不再有这个字段，库里那个数字还在
v5  有人加回 create_time : string    老玩家一登录，1700000000 被当成新字段的值读出来
```

v2 和 v5 单看都是"加/删字段"这类安全改动，只有基线替你记着才分辨得出来。所以基线里有一份 `retired`：记录删过的字段名和结构名，再次使用一律判为不兼容。这和 protobuf 的 `reserved` 是同一回事。

## 改名和改类型为什么不行

这两种改动在运行期不会报错，只会悄悄丢数据：

- **改名**：旧字段被当成"已删除"丢掉，新字段补零值。玩家的等级就这么归零了。
- **改类型**：`integer` 改成 `string` 之后，旧文档里的数字和新代码的类型检查对不上，写回时才炸，炸在业务代码深处。

要改名或改类型，走加字段的路：先加一个**新名字**的字段，让玩法代码同时写新旧两份，确认线上文档都带上新字段之后，再删旧字段。

## 检查工具

```sh
./bin/skyext generate schema   # 先生成
./bin/skyext schema check      # 对比基线
./bin/skyext schema accept     # 确认改动，更新基线
./bin/skyext schema retired    # 列出删过、不能再用的名字（可带结构名）
```

`.sproto` 里看不出哪些名字退休过，起名字之前可以先 `schema retired role` 查一眼：

```
这些名字不能再用，库里还躺着当时写下的值：
  role.create_time	integer
  role.nick	string
```

基线是 `example/schema/schema.lock.lua`，记录上一次确认过的结构，跟着 `.sproto` 的改动一起提交——评审时直接就能看到 schema 变了什么。

`schema check` 把每处改动按三级打印（`[级别] 结构.字段: 说明`）：

| 级别 | 含义 |
| --- | --- |
| `break` | 不兼容：改类型、改 map 的键值类型、改 array 的元素类型、重新使用删过的字段名或结构名 |
| `warn` | 能跑，但有数据代价：删字段、删结构、疑似改名 |
| `info` | 安全：加字段、加结构 |

退出码只看「和基线一致不一致」：完全一致返回 0；有 `break` 返回 1 并提示换做法；只有 `warn` / `info` 也返回 1，提示执行 `schema accept`；基线文件还不存在时同样返回 1。CI 里跑的就是 `schema check`，所以忘了更新基线会在流水线上暴露出来，而不是等上线之后。

同一个结构里同类型的字段一删一加会被识别成疑似改名，单独提示，因为它的数据代价和普通删字段不是一回事。

墓碑按结构隔离：`role.create_time` 退休了，不影响 `bag` 里也叫 `create_time` 的字段——两者在库里本来就是不同文档的不同键。删掉整个结构时，它的字段名连同结构名一起进墓碑。

确实需要放行不兼容改动（比如这个集合还没有线上数据）时用 `./bin/skyext schema accept --force`。被强行放行的名字会从墓碑里移走，否则之后每次检查都会再拦一遍。

## 热更

加字段、删字段这两类改动可以不重启生效：GM 命令 `reload_orm_schema` 会就地重载 schema。机制和操作步骤见 [ORM Schema 热更](hotfix.md#orm-schema-热更)。改名和改类型不要走热更。

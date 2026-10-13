# ORM schema generators

`gen_schema.lua` and `sproto2lua.lua` were incorporated from
[`sproto-orm`](https://github.com/hanxi/sproto-orm) at commit
`3f953b578045e397e587b295d8699f477d84ae1d` and are maintained here.
Their original MIT copyright notice is preserved in `LICENSE`.
The ORM runtime is maintained separately at `lualib/orm/init.lua`.

Both the schema and protocol generators use the separately pinned
`3rd/sprotodump` submodule for parsing. The checked-out parser revision
`625dc969889c37d04e22794247b15f7f5b477f87` contains no license
file; until its redistribution terms are established, release archives do
not include it. Generate schemas and protocols from a source checkout with
initialized submodules, and distribute only the generated results.

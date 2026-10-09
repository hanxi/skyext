#!/bin/bash

# cd 到 example 目录
cd "$(dirname "$0")/.."

mkdir -p ../lualib/orm
../bin/lua tools/run.lua ../3rd/sproto-orm/tools/sproto2lua.lua ../lualib/orm/schema_define.lua schema/*.sproto
../bin/lua tools/run.lua ../3rd/sproto-orm/tools/gen_schema.lua ../lualib/orm/schema.lua ../lualib/orm/schema_define.lua
stylua ../lualib/orm/

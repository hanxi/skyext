#!/bin/bash

# cd 到当前脚本目录的上层目录
cd "$(dirname "$0")/.."

mkdir -p lualib/orm
./bin/lua tools/run.lua 3rd/sproto-orm/tools/sproto2lua.lua lualib/orm/schema_define.lua schema/*.sproto
./bin/lua tools/run.lua 3rd/sproto-orm/tools/gen_schema.lua lualib/orm/schema.lua lualib/orm/schema_define.lua


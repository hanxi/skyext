all : help

.PHONY: proto copy schema autocode dist format luacheck

help:
	@echo "支持下面命令:"
	@awk '/^#/{comment=substr($$0,2)} /^[a-zA-Z0-9_-]+:/{gsub(/:/, ""); if(comment)printf "make %-12s #%s\n", $$1, comment; comment=""}' $(MAKEFILE_LIST)

include build.mk

# 初始化 submodule
init:
	git submodule update --init --recursive

# 拷贝 3rd 里必要的 lua 文件
copy:
	# 这些lua文件直接拷贝，因此如果需要修改，则应该取改 3rd 目录下的原文件
	cp -rf 3rd/sproto-orm/orm $(LUA_LIB_PATH)/
	cp -f 3rd/binaryheap.lua/src/binaryheap.lua $(LUA_LIB_PATH)/

# 编译协议
proto:
	@mkdir -p build/proto
	./tools/gen_proto.sh

# 编译 ORM 模式文件
schema:
	./tools/gen_schema.sh

# 生成代码
autocode:
	./bin/lua tools/run.lua tools/gen_roleagent_modules.lua

# 格式化 lua 代码
format:
	@echo "Formatting Lua files with stylua..."
	@stylua .

# 检查 lua 代码
luacheck:
	@echo "Checking Lua files with luacheck..."
	@luacheck .

# 打包
dist: build
	./tools/dist.sh

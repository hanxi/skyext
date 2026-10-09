all : help

.PHONY: help init build

help:
	@echo "skyext 引擎"
	@echo ""
	@echo "  make init       初始化 submodule"
	@echo "  make build      编译示例项目 (example/)"
	@echo ""
	@echo "示例项目命令请在 example/ 目录下执行："
	@echo "  cd example && make build"
	@echo "  cd example && make proto"
	@echo "  cd example && make schema"

# 初始化 submodule
init:
	git submodule update --init --recursive

# 编译示例项目（快捷入口）
build:
	$(MAKE) -C example build

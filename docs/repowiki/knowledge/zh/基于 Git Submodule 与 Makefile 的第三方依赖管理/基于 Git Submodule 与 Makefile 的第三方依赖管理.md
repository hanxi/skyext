---
kind: dependency_management
name: 基于 Git Submodule 与 Makefile 的第三方依赖管理
category: dependency_management
scope:
    - '**'
source_files:
    - .gitmodules
    - Makefile
    - build.mk
    - tools/gen_proto.sh
    - tools/gen_schema.sh
    - tools/dist.sh
    - tools/dist.py
---

## 1. 使用的系统与工具

该项目采用 **Git Submodule** + **Makefile 构建脚本** 的组合来管理第三方依赖，没有使用任何语言级包管理器（如 LuaRocks、npm、pip 等）。核心依赖来源如下：

- **Git Submodule**：所有第三方库通过 `.gitmodules` 声明，包括 Skynet 框架本身 (`skynet`) 以及 `3rd/` 目录下的 `sproto-orm`、`lua-cjson`、`binaryheap.lua`、`luafilesystem`、`libsodium`。
- **Makefile / build.mk**：负责编译 C 扩展（`.so`）、构建 Skynet 可执行文件、生成协议代码、打包分发产物。
- **Shell 脚本**：`tools/gen_proto.sh`、`tools/gen_schema.sh`、`tools/dist.sh` 等用于代码生成与发布流程。
- **Lua 运行时**：通过 `./bin/lua tools/run.lua ...` 调用项目自带的 Lua 解释器执行生成脚本。

## 2. 关键文件

- `.gitmodules`：集中声明所有子模块及其 URL，是依赖清单的唯一权威来源。
- `Makefile`：顶层入口，提供 `init`、`copy`、`proto`、`schema`、`autocode`、`dist` 等命令。
- `build.mk`：具体构建规则，定义平台检测、C 编译器参数、各 `.so` 目标及依赖关系。
- `tools/gen_proto.sh`：调用 `tools/proto2spb.lua` 将 `proto/*.sproto` 编译为 `build/proto/`。
- `tools/gen_schema.sh`：调用 `3rd/sproto-orm/tools/sproto2lua.lua` 和 `gen_schema.lua` 生成 ORM schema。
- `tools/dist.py`：由 `dist.sh` 调用的打包脚本（内容未展开）。

## 3. 架构与约定

### 依赖分类

| 类别 | 位置 | 说明 |
|---|---|---|
| 核心框架 | `skynet/` | 通过 submodule 引入，构建时 `cd skynet && $(MAKE) $(PLAT)` 编译并复制 `skynet`、`lua`、`luac` 到 `bin/` |
| C 扩展源码 | `lualib-src/` | 项目自写的 `crypto.c`、`jchash.c`、`traceback.c`，编译为 `luaclib/*.so` |
| 第三方 C/Lua 库 | `3rd/` | 以 submodule 形式引入，按原仓库结构保留源码 |
| 生成的 Lua 库 | `lualib/` | 由 `make copy` 从 `3rd/sproto-orm` 和 `3rd/binaryheap.lua` 拷贝而来 |
| 生成的协议/Schema | `build/proto/`、`lualib/orm/schema*.lua` | 由 `make proto`、`make schema` 生成 |

### 构建流程

1. `make init` → `git submodule update --init --recursive` 拉取所有依赖。
2. `make build` → 依次编译 Skynet、`lualib-src` 中的 C 扩展、`3rd/lua-cjson`、`3rd/luafilesystem`、`3rd/libsodium`（先 configure+make 静态库），再 `make copy` 拷贝必要的 Lua 文件到 `lualib/`。
3. `make proto` → 生成 `build/proto/*.lua`。
4. `make schema` → 生成 `lualib/orm/schema_define.lua` 与 `schema.lua`，并用 stylua 格式化。
5. `make dist` → 调用 `tools/dist.sh` → `tools/dist.py` 打包发布。

### 平台支持

`build.mk` 通过 `uname -s` 自动识别 `linux`、`macosx`、`freebsd`、`mingw`（交叉编译），并为不同平台设置不同的链接参数（如 Windows 下链接 `-lws2_32 -lgdi32`，macOS 使用 `-dynamiclib -Wl,-undefined,dynamic_lookup`）。

## 4. 约定与约束

- **所有第三方依赖必须通过 Git Submodule 引入**，不得直接粘贴源码或安装到全局路径。新增依赖需在 `.gitmodules` 中注册，并在 `build.mk` 中添加对应的编译规则。
- **Lua 第三方库的拷贝策略**：只有被 `make copy` 显式拷贝的文件才会进入 `lualib/`（当前为 `3rd/sproto-orm/orm` 和 `3rd/binaryheap.lua/src/binaryheap.lua`），修改应直接编辑 `3rd/` 下的源文件，而非 `lualib/` 中的副本。
- **C 扩展统一输出到 `luaclib/`**：所有 `.so` 文件由 `build.mk` 中的规则生成，名称固定为 `jchash.so`、`cjson.so`、`traceback.so`、`lfs.so`、`crypto.so`。
- **libsodium 以静态库方式集成**：构建时进入 `3rd/libsodium` 执行 `./configure --disable-shared --enable-static --with-pic`，然后链接其 `.a` 产物。
- **Skynet 作为子模块而非系统依赖**：项目不假设系统中已安装 Skynet，而是将其作为子模块完整纳入版本控制，构建时独立编译。
- **代码生成产物不被版本控制**：`build/proto/`、`lualib/orm/schema*.lua` 由脚本生成，提交前需重新运行对应 `make` 目标。
- **无私有包管理器或锁文件**：项目不使用 lockfile（如 `package-lock.json`、`go.sum`），依赖版本锁定完全依赖 Git Submodule 指向的特定 commit SHA。
- **CI 与本地构建一致**：`.github/workflows/build-release.yml` 与 `lint.yml` 复用相同的 `make` 目标，保证依赖拉取与构建流程一致。

## 5. 适用性判断

本仓库存在完整的第三方依赖管理体系（Git Submodule + Makefile 构建 + 代码生成脚本），因此该类别适用，置信度为 high。
---
kind: build_system
name: SkyExt 构建与分发系统（Make + Lua 工具链 + GitHub Actions）
category: build_system
scope:
    - '**'
source_files:
    - Makefile
    - build.mk
    - tools/dist.py
    - tools/dist.sh
    - tools/gen_proto.sh
    - tools/gen_schema.sh
    - .github/workflows/build-release.yml
    - .github/workflows/lint.yml
    - tools/hotfix.sh
    - tools/hotfix.lua
    - tools/run.lua
    - tools/proto2spb.lua
---

## 1. 构建系统与总体方案

本项目采用 **分层 Makefile + 自研 Lua 工具脚本 + GitHub Actions** 的混合构建体系：
- `Makefile` 仅暴露顶层目标（`init`/`copy`/`proto`/`schema`/`autocode`/`format`/`lint`/`dist`），核心编译逻辑委托给 `build.mk`。
- `build.mk` 负责编译 Skynet 内核、C 扩展（`jchash.so`、`cjson.so`、`traceback.so`、`lfs.so`、`crypto.so`）以及跨平台产物（`linux`/`macosx`/`freebsd`/`mingw`）。
- 协议与 ORM Schema 代码生成通过 `tools/gen_proto.sh`、`tools/gen_schema.sh` 调用 `bin/lua tools/run.lua` 执行 Lua 侧生成器。
- 最终打包由 Python 脚本 `tools/dist.py` 完成，输出 `skyext.zip`。
- CI 使用 `.github/workflows/build-release.yml` 在四个平台并行构建并发布 Release；`.github/workflows/lint.yml` 在 PR 上运行 `luacheck` 与 `stylua --check`。

## 2. 关键文件与职责

| 文件 | 职责 |
|---|---|
| `Makefile` | 顶层入口，定义 `proto`/`schema`/`autocode`/`dist`/`format`/`lint` 等命令 |
| `build.mk` | 平台检测（`PLAT = freebsd linux macosx mingw`）、Skynet 编译、C 扩展编译、`cleanall` |
| `tools/dist.py` | 收集 `*.so`、将 `*.lua` 经 `bin/luac` 编译为字节码、复制 `etc/tools/bin/proto/schema/build`、排除 `3rd` 目录并产出 `skyext.zip` |
| `tools/gen_proto.sh` | 调用 `tools/proto2spb.lua` 把 `proto/*.sproto` 编译到 `build/proto` |
| `tools/gen_schema.sh` | 用 `sproto-orm` 的 `sproto2lua.lua`/`gen_schema.lua` 生成 `lualib/orm/schema_define.lua` 与 `schema.lua` |
| `tools/hotfix.sh` / `hotfix.lua` | 热更新配置刷新流程 |
| `.github/workflows/build-release.yml` | 四平台矩阵构建（Windows/Linux/macOS/FreeBSD），tag `v*` 触发 Release |
| `.github/workflows/lint.yml` | PR/Push main 时运行 luacheck + stylua --check |
| `skynet/` | 子模块，`make $(PLAT)` 编译出 `skynet`/`lua`/`luac` 可执行文件 |
| `3rd/` | Git Submodule 引入的第三方库（libsodium、lua-cjson、luafilesystem、binaryheap.lua、sproto-orm） |

## 3. 架构与约定

### 3.1 多平台交叉编译
- `build.mk` 通过 `uname -s` 自动推断 `PLAT`，也支持显式 `make linux/macosx/freebsd/mingw`。
- Windows 目标使用 `x86_64-w64-mingw32-gcc` 交叉编译，链接 `-static-libgcc -lpthread -lm -lws2_32 -lgdi32`，产物带 `.exe` 后缀。
- macOS 使用 `-dynamiclib -Wl,-undefined,dynamic_lookup` 动态加载 C 扩展。
- libsodium 通过 `./configure --disable-shared --enable-static --with-pic` 静态编译后链接进 `crypto.so`。

### 3.2 C 扩展清单
`LUA_CLIB = jchash cjson traceback lfs crypto`，每个 `.so` 对应一个独立规则，依赖 `lualib-src/` 或 `3rd/` 下的源码。

### 3.3 代码生成流水线
```text
proto/*.sproto ──→ tools/gen_proto.sh ──→ build/proto/*.spbcfg / *.spb
schema/*.sproto ──→ tools/gen_schema.sh ──→ lualib/orm/schema_define.lua + schema.lua
app/role/roleagent/modules/* ──→ autocode (gen_roleagent_modules.lua) ──→ 自动生成模块路由
```
所有生成步骤均通过 `bin/lua tools/run.lua` 统一入口执行，保证运行环境一致。

### 3.4 打包与发布
- `make dist` → `tools/dist.sh` → `tools/dist.py`。
- `dist.py` 会：① 复制所有 `*.so`；② 对 `*.lua` 调用 `bin/luac` 编译为字节码（跳过已是 `.luac` 的文件）；③ 创建 `logs/`；④ 复制 `etc/tools/bin/proto/schema/build`；⑤ 复制 `README.md`/`LICENSE`；⑥ 排除 `3rd` 根目录及 `tools/{mongodb,etcd}` 的数据目录；⑦ 生成 `skyext.zip` 并清理临时 `dist/`。
- CI 的 `build-release.yml` 在 `push main` 或 `tag v*` 时触发，使用 `debian:13` 容器 + `macos-latest` 分别构建四个平台产物，并通过 `softprops/action-gh-release@v1` 发布 Release。

### 3.5 代码质量门禁
- `Makefile` 提供 `format`（`stylua .`）和 `lint`（`luacheck .`）本地命令。
- `.github/workflows/lint.yml` 在 PR/Push main 上强制运行 `luacheck` 与 `stylua --check`，失败则阻断合并。
- 格式化风格由根目录 `.stylua.toml`、`.styluaignore` 与 `.luacheckrc` 统一管理。

## 4. 约定与约束

- **必须先初始化子模块**：首次克隆需执行 `make init`（`git submodule update --init --recursive`），否则 `3rd/libsodium`、`3rd/lua-cjson`、`3rd/luafilesystem`、`3rd/sproto-orm`、`skynet/` 等路径不存在。
- **构建顺序**：`make build` 会依次编译 Skynet、C 扩展、执行 `copy`（拷贝 `3rd/sproto-orm/orm`、`binaryheap.lua` 到 `lualib/`），并创建 `logs/`。协议/Schema 生成是独立目标，需在 `make build` 之后单独执行 `make proto`、`make schema`。
- **Lua 代码必须通过 luacheck 且符合 Stylua 格式**：CI 的 lint job 会在 PR 上拒绝不符合规范的提交。
- **发布产物不包含源码级第三方库**：`dist.py` 明确排除 `3rd/` 目录，运行时依赖已编译好的 `.so` 与生成的 Lua 字节码。
- **版本发布以 tag `v*` 为准**：只有匹配 `refs/tags/v*` 才会触发 Release 阶段，普通 push 仅上传 artifact。
- **跨平台产物命名**：CI 固定产出 `skyext-windows.zip`、`skyext-linux.zip`、`skyext-macosx.zip`、`skyext-freebsd.zip`，Release 阶段再重新 zip 为同名文件。

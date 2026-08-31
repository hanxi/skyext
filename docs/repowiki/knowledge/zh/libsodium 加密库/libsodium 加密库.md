---
kind: external_dependency
name: libsodium 加密库
slug: libsodium
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - lualib-src/crypto.c
    - Makefile
    - build.mk
---

项目通过 C 扩展 `lualib-src/crypto.c` 集成 libsodium 加密库，用于底层加解密能力。编译期通过 Makefile/build.mk 链接到 skynet 二进制，Lua 侧通过 require 调用。
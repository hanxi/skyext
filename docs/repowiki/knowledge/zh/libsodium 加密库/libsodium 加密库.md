---
kind: external_dependency
name: OpenSSL 加密库
slug: openssl-crypto
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

## 1. 概述

项目通过 C 扩展 `lualib-src/crypto.c` 提供底层加解密能力。该模块基于 **系统 OpenSSL** 的 HMAC/EVP API 实现 HMAC-SHA256、HMAC-SHA512 签名以及 Base64URL 编解码，编译时链接 `-lssl -lcrypto`，运行时依赖系统已安装的 OpenSSL 共享库。

> **历史变更**：早期版本使用 libsodium 静态库（`crypto_auth_hmacsha256`/`crypto_auth_hmacsha512`），后迁移至系统 OpenSSL 以简化依赖管理，不再需要 libsodium 子模块。

## 2. C 实现细节

### 2.1 HMAC 签名

`crypto.c` 使用 OpenSSL 的 `HMAC()` 一次性调用接口：

```c
// HMAC-SHA256
HMAC(EVP_sha256(), key, key_len, msg, msg_len, out, &out_len);

// HMAC-SHA512
HMAC(EVP_sha512(), key, key_len, msg, msg_len, out, &out_len);
```

- 无需显式初始化（已移除早期的 `sodium_init()` 调用）。
- 输出长度由 EVP 摘要算法决定：SHA256 为 32 字节，SHA512 为 64 字节。

### 2.2 Base64URL 编解码

Base64URL 编解码为纯 C 实现（不依赖 OpenSSL），使用 URL-safe 字符集（`A-Z a-z 0-9 - _`），无填充（no padding）。

## 3. Lua API

Lua 侧通过 `require "crypto"` 加载 C 扩展，提供以下方法：

| 方法 | 签名 | 说明 |
|---|---|---|
| `crypto.hmac_sha256(key, msg)` | `(string, string) → string` | 返回 HMAC-SHA256 签名的原始字节（32 字节） |
| `crypto.hmac_sha512(key, msg)` | `(string, string) → string` | 返回 HMAC-SHA512 签名的原始字节（64 字节） |
| `crypto.base64url_encode(data)` | `(string) → string` | Base64URL 编码（无填充） |
| `crypto.base64url_decode(data)` | `(string) → string` | Base64URL 解码 |

典型用例为 JWT 签名：先对 header.payload 进行 `hmac_sha256`，再 `base64url_encode` 得到 signature 部分。

## 4. 构建

- `build.mk` 中 `crypto.so` 的编译规则链接 `-lssl -lcrypto`（系统 OpenSSL）。
- 不再需要 libsodium 子模块，`.gitmodules` 中已移除 libsodium 条目。
- 构建前需确保系统已安装 OpenSSL 开发包（如 Debian/Ubuntu 的 `libssl-dev`，CentOS/RHEL 的 `openssl-devel`）。

## 5. 约束

- 依赖系统 OpenSSL >= 1.1.0（需支持 `HMAC()` 单次调用 API）。
- `crypto.so` 编译产物位于 `luaclib/crypto.so`，由 Skynet 的 `lua_cpath` 搜索路径加载。
- Base64URL 实现不含填充字符（`=`），与 RFC 4648 Section 5 一致。

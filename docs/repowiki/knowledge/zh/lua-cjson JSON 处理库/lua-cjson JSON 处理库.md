---
kind: external_dependency
name: lua-cjson JSON 处理库
slug: lua-cjson
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - 3rd/lua-cjson
---

项目通过 `3rd/lua-cjson` 子模块引入 lua-cjson，提供高性能 JSON 编解码能力，供 HTTP 服务及 GM 接口使用。
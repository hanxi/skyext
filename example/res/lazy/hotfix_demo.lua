-- 热更示例专用配表，只被 example/hotfix/20260120-patch1 使用，产品代码不引用。
-- 验证热更：改 version 后执行 hotfix refresh，再按 docs/guide/hotfix.md 的流程执行，
-- code1.lua 的返回值会变成新的 version
return {
    version = 1,
}

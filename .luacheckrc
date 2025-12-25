std = "max"
unused_args = false
redefined = false
max_line_length = false

globals = {
    "skynet",
    "SERVICE_NAME",
    "SERVICE_PATH",
    "SERVICE_ARGS",
    "LUA_SERVICE",
    "LUA_PATH",
    "LUA_CPATH",
}

ignore = {
    "211/_ENV", -- unused variable _ENV
    "212", -- unused argument
}

exclude_files = {
    "3rd/**",
    "etc/**",
    "skynet/**",
}

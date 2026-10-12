#define LUA_LIB

#include <lauxlib.h>
#include <lua.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#else
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

struct env_pair {
    char *key;
    char *value;
};

static void
free_env(struct env_pair *env, size_t count) {
    if (env == NULL) return;
    for (size_t i = 0; i < count; i++) {
        free(env[i].key);
        free(env[i].value);
    }
    free(env);
}

static struct env_pair *
read_env(lua_State *L, size_t *count) {
    struct env_pair *env = NULL;
    *count = 0;
    lua_getfield(L, 2, "env");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return NULL;
    }
    luaL_checktype(L, -1, LUA_TTABLE);
    size_t capacity = 0;
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        const char *key = luaL_checkstring(L, -2);
        const char *value = luaL_checkstring(L, -1);
        luaL_argcheck(L, key[0] && strchr(key, '=') == NULL, 2, "invalid environment variable name");
        if (*count == capacity) {
            capacity = capacity ? capacity * 2 : 8;
            struct env_pair *next = realloc(env, capacity * sizeof(*env));
            if (!next) {
                free_env(env, *count);
                luaL_error(L, "out of memory");
            }
            env = next;
        }
        env[*count].key = strdup(key);
        env[*count].value = strdup(value);
        if (!env[*count].key || !env[*count].value) {
            free(env[*count].key);
            free(env[*count].value);
            free_env(env, *count);
            luaL_error(L, "out of memory");
        }
        (*count)++;
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return env;
}

#ifdef _WIN32
static wchar_t *
utf8_to_wide(const char *s) {
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (!length) return NULL;
    wchar_t *wide = malloc((size_t)length * sizeof(*wide));
    if (!wide || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, wide, length)) {
        free(wide);
        return NULL;
    }
    return wide;
}

static void
append_char(wchar_t **dest, size_t *capacity, size_t *length, wchar_t c) {
    if (*length + 2 > *capacity) {
        *capacity = *capacity ? *capacity * 2 : 256;
        wchar_t *next = realloc(*dest, *capacity * sizeof(**dest));
        if (!next) abort();
        *dest = next;
    }
    (*dest)[(*length)++] = c;
    (*dest)[*length] = L'\0';
}

static void
append_arg(wchar_t **line, size_t *capacity, size_t *length, const wchar_t *arg) {
    if (*length) append_char(line, capacity, length, L' ');
    append_char(line, capacity, length, L'"');
    for (const wchar_t *p = arg; ; p++) {
        size_t slashes = 0;
        while (*p == L'\\') {
            slashes++;
            p++;
        }
        if (*p == L'"' || *p == L'\0') {
            for (size_t i = 0; i < slashes * 2; i++) append_char(line, capacity, length, L'\\');
            if (*p == L'\0') break;
            append_char(line, capacity, length, L'\\');
            append_char(line, capacity, length, L'"');
        } else {
            for (size_t i = 0; i < slashes; i++) append_char(line, capacity, length, L'\\');
            append_char(line, capacity, length, *p);
        }
    }
    append_char(line, capacity, length, L'"');
}

static wchar_t *
command_line(lua_State *L, char **args, size_t count) {
    wchar_t *line = NULL;
    size_t capacity = 0, length = 0;
    for (size_t i = 0; i < count; i++) {
        wchar_t *arg = utf8_to_wide(args[i]);
        if (!arg) {
            free(line);
            luaL_error(L, "invalid UTF-8 argument");
        }
        append_arg(&line, &capacity, &length, arg);
        free(arg);
    }
    return line;
}

static int
run(lua_State *L, char **args, size_t count, const char *cwd,
    const struct env_pair *env, size_t env_count, lua_Number timeout) {
    wchar_t *line = command_line(L, args, count);
    wchar_t *directory = cwd ? utf8_to_wide(cwd) : NULL;
    if (cwd && !directory) {
        free(line);
        return luaL_error(L, "invalid UTF-8 working directory");
    }

    wchar_t **keys = calloc(env_count, sizeof(*keys));
    wchar_t **previous = calloc(env_count, sizeof(*previous));
    int *existed = calloc(env_count, sizeof(*existed));
    if (env_count && (!keys || !previous || !existed)) abort();
    size_t applied = 0;
    for (size_t i = 0; i < env_count; i++) {
        keys[i] = utf8_to_wide(env[i].key);
        wchar_t *value = utf8_to_wide(env[i].value);
        if (!keys[i] || !value) {
            free(value);
            break;
        }
        DWORD size = GetEnvironmentVariableW(keys[i], NULL, 0);
        existed[i] = size != 0 || GetLastError() != ERROR_ENVVAR_NOT_FOUND;
        if (size) {
            previous[i] = malloc(size * sizeof(wchar_t));
            if (!previous[i] || GetEnvironmentVariableW(keys[i], previous[i], size) >= size) abort();
        } else if (existed[i]) {
            previous[i] = utf8_to_wide("");
        }
        if (!SetEnvironmentVariableW(keys[i], value)) {
            free(value);
            break;
        }
        free(value);
        applied++;
    }

    STARTUPINFOW startup = { 0 };
    PROCESS_INFORMATION process = { 0 };
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    BOOL created = applied == env_count && CreateProcessW(
        NULL, line, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, directory, &startup, &process
    );
    DWORD create_error = created ? 0 : GetLastError();
    for (size_t i = applied; i > 0; i--) {
        size_t index = i - 1;
        SetEnvironmentVariableW(keys[index], existed[index] ? previous[index] : NULL);
    }
    for (size_t i = 0; i < env_count; i++) {
        free(keys[i]);
        free(previous[i]);
    }
    free(keys);
    free(previous);
    free(existed);
    free(directory);
    free(line);
    if (!created) return luaL_error(L, "CreateProcess failed (%lu)", (unsigned long)create_error);

    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = { 0 };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))
        || !AssignProcessToJobObject(job, process.hProcess)) {
        DWORD error = GetLastError();
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        if (job) CloseHandle(job);
        return luaL_error(L, "cannot attach subprocess to job (%lu)", (unsigned long)error);
    }
    ResumeThread(process.hThread);
    DWORD wait_ms = timeout > 0 ? (DWORD)(timeout * 1000) : INFINITE;
    DWORD result = WaitForSingleObject(process.hProcess, wait_ms);
    int timed_out = result == WAIT_TIMEOUT;
    if (timed_out) {
        TerminateJobObject(job, 124);
        WaitForSingleObject(process.hProcess, INFINITE);
    }
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    if (result == WAIT_FAILED) return luaL_error(L, "WaitForSingleObject failed");
    lua_pushinteger(L, timed_out ? 124 : (lua_Integer)exit_code);
    lua_pushboolean(L, timed_out);
    return 2;
}
#else
static double
monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int
run(lua_State *L, char **args, size_t count, const char *cwd,
    const struct env_pair *env, size_t env_count, lua_Number timeout) {
    (void)count;
    pid_t pid = fork();
    if (pid < 0) return luaL_error(L, "fork failed: %s", strerror(errno));
    if (pid == 0) {
        if (timeout > 0 && setpgid(0, 0) != 0) _exit(127);
        if (cwd && chdir(cwd) != 0) _exit(127);
        for (size_t i = 0; i < env_count; i++) {
            if (setenv(env[i].key, env[i].value, 1) != 0) _exit(127);
        }
        execvp(args[0], args);
        perror(args[0]);
        _exit(127);
    }
    if (timeout > 0) setpgid(pid, pid);
    double deadline = timeout > 0 ? monotonic_seconds() + timeout : 0;
    int status = 0, timed_out = 0;
    for (;;) {
        pid_t done = waitpid(pid, &status, timeout > 0 ? WNOHANG : 0);
        if (done == pid) break;
        if (done < 0) {
            if (errno == EINTR) continue;
            return luaL_error(L, "waitpid failed: %s", strerror(errno));
        }
        if (monotonic_seconds() >= deadline) {
            timed_out = 1;
            kill(-pid, SIGTERM);
            double grace = monotonic_seconds() + 5;
            while (monotonic_seconds() < grace) {
                done = waitpid(pid, &status, WNOHANG);
                if (done == pid) break;
                if (done < 0 && errno != EINTR) break;
                struct timespec pause = { 0, 20000000 };
                nanosleep(&pause, NULL);
            }
            kill(-pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
            break;
        }
        struct timespec pause = { 0, 20000000 };
        nanosleep(&pause, NULL);
    }
    if (timeout > 0) kill(-pid, SIGKILL);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1);
    lua_pushinteger(L, timed_out ? 124 : code);
    lua_pushboolean(L, timed_out);
    return 2;
}
#endif

struct child_process {
#ifdef _WIN32
    HANDLE handle;
    DWORD pid;
#else
    pid_t pid;
#endif
    int active;
};

static int
child_id(lua_State *L) {
    struct child_process *child = luaL_checkudata(L, 1, "tool_process.child");
    lua_pushinteger(L, (lua_Integer)child->pid);
    return 1;
}

static int
child_close(lua_State *L) {
    struct child_process *child = luaL_checkudata(L, 1, "tool_process.child");
    if (!child->active) return 0;
#ifdef _WIN32
    if (WaitForSingleObject(child->handle, 0) == WAIT_TIMEOUT) {
        TerminateProcess(child->handle, 1);
        WaitForSingleObject(child->handle, INFINITE);
    }
    CloseHandle(child->handle);
#else
    int status;
    pid_t done = waitpid(child->pid, &status, WNOHANG);
    if (done == 0) {
        kill(child->pid, SIGTERM);
        double deadline = monotonic_seconds() + 1;
        do {
            struct timespec pause = { 0, 20000000 };
            nanosleep(&pause, NULL);
            done = waitpid(child->pid, &status, WNOHANG);
        } while (done == 0 && monotonic_seconds() < deadline);
        if (done == 0) {
            kill(child->pid, SIGKILL);
            while (waitpid(child->pid, &status, 0) < 0 && errno == EINTR) { }
        }
    }
#endif
    child->active = 0;
    return 0;
}

static int
lspawn(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    size_t count = lua_rawlen(L, 1);
    luaL_argcheck(L, count > 0, 1, "expected non-empty argv table");
    char **args = calloc(count + 1, sizeof(*args));
    if (!args) return luaL_error(L, "out of memory");
    for (size_t i = 0; i < count; i++) {
        lua_rawgeti(L, 1, (lua_Integer)i + 1);
        args[i] = (char *)luaL_checkstring(L, -1);
        lua_pop(L, 1);
    }
    struct child_process *child = lua_newuserdatauv(L, sizeof(*child), 0);
    memset(child, 0, sizeof(*child));
    luaL_setmetatable(L, "tool_process.child");
#ifdef _WIN32
    wchar_t *line = command_line(L, args, count);
    STARTUPINFOW startup = { 0 };
    PROCESS_INFORMATION process = { 0 };
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    BOOL created = CreateProcessW(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process);
    DWORD error = created ? 0 : GetLastError();
    free(line);
    free(args);
    if (!created) return luaL_error(L, "CreateProcess failed (%lu)", (unsigned long)error);
    CloseHandle(process.hThread);
    child->handle = process.hProcess;
    child->pid = process.dwProcessId;
#else
    extern char **environ;
    int error = posix_spawnp(&child->pid, args[0], NULL, NULL, args, environ);
    free(args);
    if (error) return luaL_error(L, "posix_spawnp failed: %s", strerror(error));
#endif
    child->active = 1;
    return 1;
}

static int
lrun(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (lua_isnoneornil(L, 2)) {
        lua_settop(L, 1);
        lua_newtable(L);
    } else {
        luaL_checktype(L, 2, LUA_TTABLE);
    }
    size_t count = lua_rawlen(L, 1);
    luaL_argcheck(L, count > 0, 1, "expected non-empty argv table");
    char **args = calloc(count + 1, sizeof(*args));
    if (!args) return luaL_error(L, "out of memory");
    for (size_t i = 0; i < count; i++) {
        lua_rawgeti(L, 1, (lua_Integer)i + 1);
        args[i] = (char *)luaL_checkstring(L, -1);
        lua_pop(L, 1);
    }
    lua_getfield(L, 2, "cwd");
    const char *cwd = lua_isnil(L, -1) ? NULL : luaL_checkstring(L, -1);
    lua_getfield(L, 2, "timeout");
    lua_Number timeout = lua_isnil(L, -1) ? 0 : luaL_checknumber(L, -1);
    luaL_argcheck(L, timeout >= 0 && timeout < 4000000, 2, "invalid timeout");
    size_t env_count;
    struct env_pair *env = read_env(L, &env_count);
    int result = run(L, args, count, cwd, env, env_count, timeout);
    free_env(env, env_count);
    free(args);
    return result;
}

LUAMOD_API int
luaopen_tool_process(lua_State *L) {
    luaL_checkversion(L);
    luaL_newmetatable(L, "tool_process.child");
    lua_pushcfunction(L, child_close);
    lua_setfield(L, -2, "__gc");
    lua_newtable(L);
    lua_pushcfunction(L, child_close);
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, child_id);
    lua_setfield(L, -2, "id");
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    luaL_Reg methods[] = {
        { "run", lrun },
        { "spawn", lspawn },
        { NULL, NULL },
    };
    luaL_newlib(L, methods);
    return 1;
}

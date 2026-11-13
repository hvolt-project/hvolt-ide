#include <dlfcn.h>
#include <vector>
#include <cstdio>
#include <string>
#include "napi/native_api.h"

#include "sandbox_sh.h"

#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <sys/wait.h>
#include <unistd.h>
#include <hilog/log.h>

namespace {
std::string DirOfSelf()
{
    Dl_info info{};
    if (dladdr(reinterpret_cast<void *>(&DirOfSelf), &info) != 0 && info.dli_fname != nullptr) {
        std::string p(info.dli_fname);
        auto pos = p.find_last_of('/');
        if (pos != std::string::npos) {
            return p.substr(0, pos);
        }
    }
    return std::string(".");
}

std::string ProbeOnce()
{
    const std::string dir = DirOfSelf();
    const std::string path = dir + "/libes2abc.so";
    void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        return std::string("dlopen-fail:") + dlerror() + "@" + path;
    }
    auto fn = reinterpret_cast<const char *(*)()>(dlsym(h, "es2abc_api_version"));
    if (fn == nullptr) {
        return std::string("dlsym-fail@") + path;
    }
    return std::string("ok:") + fn() + "@" + path;
}

std::string RunEs2abc()
{
    const std::string dir = DirOfSelf();
    // app sandbox files dir of this bundle
    const std::string base = "/data/storage/el2/base/files/";
    const std::string tsPath = base + "probe.ts";
    const std::string outPath = base + "probe.abc";
    FILE *f = fopen(tsPath.c_str(), "w");
    if (f == nullptr) {
        return std::string("write-fail@") + tsPath;
    }
    fputs("let x: number = 1;\nconsole.log(x);\n", f);
    fclose(f);

    void *h = dlopen((dir + "/libes2abc.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        return std::string("dlopen-fail:") + dlerror();
    }
    auto entry = reinterpret_cast<int (*)(int, const char **)>(dlsym(h, "es2abc_entry"));
    if (entry == nullptr) {
        return "dlsym-entry-fail";
    }
    const char *argv[] = { "es2abc", "--output", outPath.c_str(), tsPath.c_str() };
    const int rc = entry(4, argv);
    FILE *o = fopen(outPath.c_str(), "rb");
    long size = -1;
    if (o != nullptr) {
        fseek(o, 0, SEEK_END);
        size = ftell(o);
        fclose(o);
    }
    return "run:rc=" + std::to_string(rc) + ",abc=" + std::to_string(size);
}

std::string RunHvolt()
{
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        return std::string("hvolt-dlopen-fail:") + dlerror();
    }
    auto run = reinterpret_cast<char *(*)(const char *, const char *)>(dlsym(h, "hvolt_run"));
    auto free_fn = reinterpret_cast<void (*)(char *)>(dlsym(h, "hvolt_free"));
    auto ver = reinterpret_cast<const char *(*)(void)>(dlsym(h, "hvolt_lib_version"));
    if (run == nullptr || free_fn == nullptr || ver == nullptr) {
        return "hvolt-dlsym-fail";
    }
    const std::string cwd = "/data/storage/el2/base/files/";
    char *res = run("[\"-V\"]", cwd.c_str());
    std::string out = res == nullptr ? std::string("null") : std::string(res);
    if (res != nullptr) {
        free_fn(res);
    }
    return "hvolt:" + std::string(ver()) + "->" + out;
}

std::string BuildInProc(const std::string &filesDir)
{
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        return std::string("hvolt-dlopen-fail:") + dlerror();
    }
    auto run = reinterpret_cast<char *(*)(const char *, const char *)>(dlsym(h, "hvolt_run"));
    auto free_fn = reinterpret_cast<void (*)(char *)>(dlsym(h, "hvolt_free"));
    if (run == nullptr || free_fn == nullptr) {
        return "hvolt-dlsym-fail";
    }
    setenv("HOME", filesDir.c_str(), 1);
    setenv("HVOLT_ES2ABC_LIB", (dir + "/libes2abc.so").c_str(), 1);
    const std::string proj = filesDir + "/stage/proj";
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "ideprobe", "%{public}s", ("build-start:" + proj).c_str());
    char *res = run("[\"build\"]", proj.c_str());
    std::string out = res == nullptr ? std::string("null") : std::string(res);
    if (res != nullptr) {
        free_fn(res);
    }
    return "build:" + out;
}

// ArkWeb logs from its own threads into the same fds, so the captured text
// carries chromium lines; they are not hvolt's output.
// The envelope is one line of JSON: a command's captured output is escaped inside it, so a
// line the command itself printed can contain any noise marker verbatim. Filtering by
// substring would drop the whole envelope — the build result carries the ArkWeb lines it
// captured. Only lines that are the noise itself are removed, and an envelope never is.
static bool IsEnvelopeLine(const std::string &line)
{
    size_t i = 0;
    while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) {
        i++;
    }
    return i < line.size() && line[i] == '{';
}

static std::string StripNativeNoise(const std::string &in)
{
    std::string out;
    size_t i = 0;
    while (i <= in.size()) {
        size_t nl = in.find('\n', i);
        const size_t end = (nl == std::string::npos) ? in.size() : nl;
        const std::string line = in.substr(i, end - i);
        if (IsEnvelopeLine(line) ||
            (line.find("arkweb/chromium") == std::string::npos &&
             line.find("ExternalBeginFrameSourceOHOS") == std::string::npos &&
             line.find("NWeb") != 0)) {
            out += line;
            out += '\n';
        }
        if (nl == std::string::npos) {
            break;
        }
        i = nl + 1;
    }
    return out;
}

std::string HvoltCallImpl(const std::string &argvJson, const std::string &cwd, const std::string &filesDir)
{
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        return std::string("hvolt-dlopen-fail:") + dlerror();
    }
    auto run = reinterpret_cast<char *(*)(const char *, const char *)>(dlsym(h, "hvolt_run"));
    auto free_fn = reinterpret_cast<void (*)(char *)>(dlsym(h, "hvolt_free"));
    if (run == nullptr || free_fn == nullptr) {
        return "hvolt-dlsym-fail";
    }
    setenv("HOME", filesDir.c_str(), 1);
    setenv("HVOLT_ES2ABC_LIB", (dir + "/libes2abc.so").c_str(), 1);
    char *res = run(argvJson.c_str(), cwd.empty() ? nullptr : cwd.c_str());
    std::string out = res == nullptr ? std::string("null") : std::string(res);
    if (res != nullptr) {
        free_fn(res);
    }
    return out;
}

// Spawn a binary from the app sandbox and report how it ended: the device IDE
// needs to know whether exec is allowed at all before it promises native builds.
napi_value ExecProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    std::string path(len, '\0');
    napi_get_value_string_utf8(env, argv[0], &path[0], len + 1, &len);

    std::string result;
    const int chmod_rc = chmod(path.c_str(), 0755);
    int fds[2];
    if (pipe(fds) != 0) {
        result = "pipe-fail";
    } else {
        const pid_t pid = fork();
        if (pid < 0) {
            result = std::string("fork-fail errno=") + std::to_string(errno);
            close(fds[0]);
            close(fds[1]);
        } else if (pid == 0) {
            dup2(fds[1], 1);
            dup2(fds[1], 2);
            close(fds[0]);
            close(fds[1]);
            char *const args[] = { const_cast<char *>(path.c_str()), nullptr };
            execv(path.c_str(), args);
            const int err = errno;
            char msg[64];
            const int n = snprintf(msg, sizeof(msg), "exec-fail errno=%d\n", err);
            ssize_t ignored = write(1, msg, static_cast<size_t>(n));
            (void)ignored;
            _exit(127);
        } else {
            close(fds[1]);
            char buf[512] = { 0 };
            const ssize_t n = read(fds[0], buf, sizeof(buf) - 1);
            close(fds[0]);
            int status = 0;
            waitpid(pid, &status, 0);
            const int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            result = std::string("chmod=") + std::to_string(chmod_rc) + " exit=" + std::to_string(code) +
                     " out=" + std::string(buf, n > 0 ? static_cast<size_t>(n) : 0);
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "ideprobe", "exec %{public}s", result.c_str());
    napi_value out = nullptr;
    napi_create_string_utf8(env, result.c_str(), result.size(), &out);
    return out;
}

napi_value HvoltCall(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto read = [&](size_t i) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[i], nullptr, 0, &len);
        std::string s(len, '\0');
        napi_get_value_string_utf8(env, argv[i], &s[0], len + 1, &len);
        return s;
    };
    const std::string r = StripNativeNoise(HvoltCallImpl(read(0), read(1), read(2)));
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "ideprobe", "%{public}s", r.c_str());
    napi_value out = nullptr;
    napi_create_string_utf8(env, r.c_str(), r.size(), &out);
    return out;
}

napi_value Build(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    std::string in(len, '\0');
    napi_get_value_string_utf8(env, argv[0], &in[0], len + 1, &len);
    const std::string r = BuildInProc(in);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "ideprobe", "%{public}s", r.c_str());
    napi_value out = nullptr;
    napi_create_string_utf8(env, r.c_str(), r.size(), &out);
    return out;
}

napi_value Probe(napi_env env, napi_callback_info info)
{
    const std::string r = ProbeOnce() + " | " + RunEs2abc() + " | " + RunHvolt();
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "ideprobe", "%{public}s", r.c_str());
    napi_value out = nullptr;
    napi_create_string_utf8(env, r.c_str(), r.size(), &out);
    return out;
}

// ─── log follower ───────────────────────────────────────────────────────────
// The follower lives in libhvolt: a thread reads the device stream and keeps the lines in
// a ring, so ArkTS polls a cursor instead of starting a command per refresh.
napi_value StreamStart(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto read = [&](size_t i) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[i], nullptr, 0, &len);
        std::string s(len, '\0');
        napi_get_value_string_utf8(env, argv[i], &s[0], len + 1, &len);
        return s;
    };
    const std::string params = read(0);
    const std::string filesDir = read(1);
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    std::string out = "hvolt-dlopen-fail";
    if (h != nullptr) {
        auto start = reinterpret_cast<char *(*)(const char *)>(dlsym(h, "hvolt_stream_start"));
        auto free_fn = reinterpret_cast<void (*)(char *)>(dlsym(h, "hvolt_free"));
        if (start != nullptr && free_fn != nullptr) {
            setenv("HOME", filesDir.c_str(), 1);
            setenv("HVOLT_ES2ABC_LIB", (dir + "/libes2abc.so").c_str(), 1);
            char *res = start(params.c_str());
            out = res == nullptr ? std::string("null") : std::string(res);
            if (res != nullptr) {
                free_fn(res);
            }
        } else {
            out = "hvolt-dlsym-fail";
        }
    }
    napi_value r = nullptr;
    napi_create_string_utf8(env, out.c_str(), out.size(), &r);
    return r;
}

napi_value StreamRead(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    double handle = 0;
    double from = 0;
    double max = 0;
    napi_get_value_double(env, argv[0], &handle);
    napi_get_value_double(env, argv[1], &from);
    napi_get_value_double(env, argv[2], &max);
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    std::string out = "hvolt-dlopen-fail";
    if (h != nullptr) {
        auto rd = reinterpret_cast<char *(*)(uint64_t, uint64_t, uint32_t)>(dlsym(h, "hvolt_stream_read"));
        auto free_fn = reinterpret_cast<void (*)(char *)>(dlsym(h, "hvolt_free"));
        if (rd != nullptr && free_fn != nullptr) {
            char *res = rd(static_cast<uint64_t>(handle), static_cast<uint64_t>(from),
                           static_cast<uint32_t>(max));
            out = res == nullptr ? std::string("null") : std::string(res);
            if (res != nullptr) {
                free_fn(res);
            }
        } else {
            out = "hvolt-dlsym-fail";
        }
    }
    napi_value r = nullptr;
    napi_create_string_utf8(env, out.c_str(), out.size(), &r);
    return r;
}

napi_value StreamNext(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    double handle = 0;
    double from = 0;
    double max = 0;
    double waitMs = 0;
    napi_get_value_double(env, argv[0], &handle);
    napi_get_value_double(env, argv[1], &from);
    napi_get_value_double(env, argv[2], &max);
    napi_get_value_double(env, argv[3], &waitMs);
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    std::string out = "hvolt-dlopen-fail";
    if (h != nullptr) {
        auto rd = reinterpret_cast<char *(*)(uint64_t, uint64_t, uint32_t, uint32_t)>(
            dlsym(h, "hvolt_stream_next"));
        auto free_fn = reinterpret_cast<void (*)(char *)>(dlsym(h, "hvolt_free"));
        if (rd != nullptr && free_fn != nullptr) {
            // Blocks here, on the worker thread, until the device produces a line or the
            // wait expires — the caller simply asks again, so there is no timer.
            char *res = rd(static_cast<uint64_t>(handle), static_cast<uint64_t>(from),
                           static_cast<uint32_t>(max), static_cast<uint32_t>(waitMs));
            out = res == nullptr ? std::string("null") : std::string(res);
            if (res != nullptr) {
                free_fn(res);
            }
        } else {
            out = "hvolt-dlsym-fail";
        }
    }
    napi_value r = nullptr;
    napi_create_string_utf8(env, out.c_str(), out.size(), &r);
    return r;
}

napi_value StreamStop(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    double handle = 0;
    napi_get_value_double(env, argv[0], &handle);
    const std::string dir = DirOfSelf();
    void *h = dlopen((dir + "/libhvolt.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h != nullptr) {
        auto stop = reinterpret_cast<void (*)(uint64_t)>(dlsym(h, "hvolt_stream_stop"));
        if (stop != nullptr) {
            stop(static_cast<uint64_t>(handle));
        }
    }
    return nullptr;
}


// --- sandbox probe ---------------------------------------------------------------------------
//
// What an app process may actually do at the syscall boundary, measured rather than assumed. Each
// line is one question with its own answer, because "the sandbox blocks X" is only useful when X
// and the evidence for it are named.
namespace {

std::string ReadFile(const char *path)
{
    FILE *f = fopen(path, "re");
    if (f == nullptr) {
        return std::string("open-fail errno=") + std::to_string(errno);
    }
    char buf[512] = { 0 };
    const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string out(buf, n);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\0')) {
        out.pop_back();
    }
    return out;
}

std::string FieldOf(const char *path, const char *key)
{
    const std::string body = ReadFile(path);
    const std::string needle = std::string(key) + ":";
    const size_t at = body.find(needle);
    if (at == std::string::npos) {
        return "absent";
    }
    size_t start = at + needle.size();
    while (start < body.size() && (body[start] == ' ' || body[start] == '\t')) {
        start += 1;
    }
    const size_t end = body.find('\n', start);
    return body.substr(start, end == std::string::npos ? std::string::npos : end - start);
}


std::string StatLink(const char *path)
{
    struct stat st;
    if (lstat(path, &st) != 0) {
        return "lstat-fail errno=" + std::to_string(errno);
    }
    if (!S_ISLNK(st.st_mode)) {
        return "not-a-link";
    }
    char buf[256] = { 0 };
    const ssize_t n = readlink(path, buf, sizeof(buf) - 1);
    return "->" + std::string(buf, n > 0 ? static_cast<size_t>(n) : 0);
}

// fork + execv, with the child's exit code and first line of output.

// Runs `path` with an explicit argv, returning the exit code and the first line of output.
std::string ExecArgv(const std::string &path, const std::vector<std::string> &args)
{
    int fds[2];
    if (pipe(fds) != 0) {
        return "pipe-fail";
    }
    const pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return std::string("fork-fail errno=") + std::to_string(errno);
    }
    if (pid == 0) {
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[0]);
        close(fds[1]);
        std::vector<char *> argv;
        argv.push_back(const_cast<char *>(path.c_str()));
        for (const auto &a : args) {
            argv.push_back(const_cast<char *>(a.c_str()));
        }
        argv.push_back(nullptr);
        execv(path.c_str(), argv.data());
        const int err = errno;
        char msg[96];
        const int n = snprintf(msg, sizeof(msg), "exec-fail errno=%d", err);
        ssize_t ignored = write(1, msg, static_cast<size_t>(n));
        (void)ignored;
        _exit(127);
    }
    close(fds[1]);
    char buf[256] = { 0 };
    const ssize_t n = read(fds[0], buf, sizeof(buf) - 1);
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    const int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    std::string out(buf, n > 0 ? static_cast<size_t>(n) : 0);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) {
        out.pop_back();
    }
    return "exit=" + std::to_string(code) + " out=" + out;
}

std::string ExecOnce(const std::string &path, const std::string &arg)
{
    int fds[2];
    if (pipe(fds) != 0) {
        return "pipe-fail";
    }
    const pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return std::string("fork-fail errno=") + std::to_string(errno);
    }
    if (pid == 0) {
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[0]);
        close(fds[1]);
        if (arg.empty()) {
            char *const args[] = { const_cast<char *>(path.c_str()), nullptr };
            execv(path.c_str(), args);
        } else {
            char *const args[] = { const_cast<char *>(path.c_str()), const_cast<char *>(arg.c_str()),
                                   nullptr };
            execv(path.c_str(), args);
        }
        const int err = errno;
        char msg[96];
        const int n = snprintf(msg, sizeof(msg), "exec-fail errno=%d", err);
        ssize_t ignored = write(1, msg, static_cast<size_t>(n));
        (void)ignored;
        _exit(127);
    }
    close(fds[1]);
    char buf[256] = { 0 };
    const ssize_t n = read(fds[0], buf, sizeof(buf) - 1);
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    const int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    std::string out(buf, n > 0 ? static_cast<size_t>(n) : 0);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) {
        out.pop_back();
    }
    return "exit=" + std::to_string(code) + " out=" + out;
}

}  // namespace

napi_value SandboxProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string cache;
    if (argc > 1 && argv[1] != nullptr) {
        size_t clen = 0;
        napi_get_value_string_utf8(env, argv[1], nullptr, 0, &clen);
        cache.assign(clen, '\0');
        napi_get_value_string_utf8(env, argv[1], &cache[0], clen + 1, &clen);
    }
    std::string dir;
    if (argc > 0) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
        dir.assign(len, '\0');
        napi_get_value_string_utf8(env, argv[0], &dir[0], len + 1, &len);
    }

    std::string out;
    out += "domain=" + ReadFile("/proc/self/attr/current");
    out += " seccomp=" + FieldOf("/proc/self/status", "Seccomp");
    out += " capeff=" + FieldOf("/proc/self/status", "CapEff");
    out += " uid=" + FieldOf("/proc/self/status", "Uid");
    out += " statusbytes=" + std::to_string(ReadFile("/proc/self/status").size());
    out += "|";

    // 1. Exec a labelled system binary: the control case.
    out += " exec_system_toybox[" + ExecOnce("/system/bin/toybox", "echo") + "]";
    out += " toybox_sh[" + ExecArgv("/system/bin/toybox", {"sh", "-c", "echo TBOX-SH-OK; id"}) + "]";
    // 2. Exec /system/bin/sh, which is what a shell tool would need.
    out += " exec_system_sh[" + ExecOnce("/system/bin/sh", "-c") + "]";
    out += " exec_bin_sh[" + ExecOnce("/bin/sh", "-c") + "]";
    out += " stat_bin_sh[" + StatLink("/bin/sh") + "]";

    // 3. Exec a byte-identical copy inside the app's own files directory.
    if (!dir.empty()) {
        const std::string copy = dir + "/probe-toybox";
        FILE *src = fopen("/system/bin/toybox", "re");
        bool copied = false;
        if (src != nullptr) {
            FILE *dst = fopen(copy.c_str(), "we");
            if (dst != nullptr) {
                char buf[16384];
                size_t n = 0;
                while ((n = fread(buf, 1, sizeof(buf), src)) > 0) {
                    fwrite(buf, 1, n, dst);
                }
                fclose(dst);
                copied = true;
            }
            fclose(src);
        }
        if (copied) {
            chmod(copy.c_str(), 0755);
            out += " exec_appdir_toybox[" + ExecOnce(copy, "echo APPDIR-OK") + "]";
        } else {
            out += " exec_appdir_toybox[copy-fail]";
        }
    }

    // 4a. RW then RX: the two-step JIT pattern, asked separately because a single RWX request
    // says nothing about whether write-then-exec is allowed.
    {
        void *jit = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (jit == MAP_FAILED) {
            out += " mmap_rw_then_rx[mmap-fail errno=" + std::to_string(errno) + "]";
        } else {
            uint32_t *w = reinterpret_cast<uint32_t *>(jit);
            w[0] = 0x528000E0u;
            w[1] = 0xD65F03C0u;
            const int mrc = mprotect(jit, 4096, PROT_READ | PROT_EXEC);
            const int merr = errno;
            if (mrc != 0) {
                out += " mmap_rw_then_rx[mprotect-fail errno=" + std::to_string(merr) + "]";
            } else {
                __builtin___clear_cache(reinterpret_cast<char *>(jit), reinterpret_cast<char *>(jit) + 8);
                auto jfn = reinterpret_cast<int (*)()>(jit);
                out += " mmap_rw_then_rx[ok call=" + std::to_string(jfn()) + "]";
            }
            munmap(jit, 4096);
        }
    }

    // 4b. File-backed executable mapping of a file the app owns.
    if (!dir.empty()) {
        const std::string target = dir + "/probe-toybox";
        const int fd = open(target.c_str(), O_RDONLY);
        if (fd < 0) {
            out += " mmap_file_exec[open-fail errno=" + std::to_string(errno) + "]";
        } else {
            void *m = mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
            out += m == MAP_FAILED
                ? " mmap_file_exec[fail errno=" + std::to_string(errno) + "]"
                : " mmap_file_exec[ok]";
            if (m != MAP_FAILED) {
                munmap(m, 4096);
            }
            close(fd);
        }
    }

    // 4c. Anonymous RWX in one request: the shape an in-process guest loader would prefer.
    void *code = mmap(nullptr, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED) {
        out += " mmap_rwx[fail errno=" + std::to_string(errno) + "]";
    } else {
        // aarch64: `mov w0, #7 ; ret`
        uint32_t *words = reinterpret_cast<uint32_t *>(code);
        words[0] = 0x528000E0u;
        words[1] = 0xD65F03C0u;
        __builtin___clear_cache(reinterpret_cast<char *>(code), reinterpret_cast<char *>(code) + 8);
        auto fn = reinterpret_cast<int (*)()>(code);
        const int value = fn();
        out += " mmap_rwx[ok call=" + std::to_string(value) + "]";
        munmap(code, 4096);
    }


    // 4d. Executable mapping of a *shipped* library, next to the guest path question: the dynamic
    // linker already maps these, so the comparison isolates "who owns the file" from "may it run".
    {
        const std::string lib = DirOfSelf() + "/libnavi.so";
        const int lfd = open(lib.c_str(), O_RDONLY);
        if (lfd < 0) {
            out += " mmap_libdir_exec[open-fail errno=" + std::to_string(errno) + "]";
        } else {
            void *m = mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, lfd, 0);
            out += m == MAP_FAILED
                ? " mmap_libdir_exec[fail errno=" + std::to_string(errno) + "]"
                : " mmap_libdir_exec[ok]";
            if (m != MAP_FAILED) {
                munmap(m, 4096);
            }
            close(lfd);
        }
        out += " exec_libdir_so[" + ExecOnce(lib, "") + "]";
    }

    // 4e. PROT_EXEC alone, anonymous: is the denial about write or about execute?
    {
        void *x = mmap(nullptr, 4096, PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        out += x == MAP_FAILED
            ? " mmap_exec_only[fail errno=" + std::to_string(errno) + "]"
            : " mmap_exec_only[ok]";
        if (x != MAP_FAILED) {
            munmap(x, 4096);
        }
    }

    // 4f. mprotect on an existing executable mapping from the linker: does the flag stick?
    {
        void *self = reinterpret_cast<void *>(&SandboxProbe);
        const int rc = mprotect(reinterpret_cast<void *>(reinterpret_cast<uintptr_t>(self) & ~0xFFFULL),
                                4096, PROT_READ | PROT_WRITE);
        out += " mprotect_code[rc=" + std::to_string(rc) + " errno=" + std::to_string(errno) + "]";
    }


    // 6. System library executable mapping: does ownership of the file decide it?
    {
        const char *cands[] = { "/system/lib64/libc.so", "/system/lib/libc.so",
                                "/system/lib64/libace_napi.z.so" };
        for (const char *cand : cands) {
            const int fd = open(cand, O_RDONLY);
            if (fd < 0) {
                out += " mmap_syslib[" + std::string(cand) + " open-fail errno=" +
                       std::to_string(errno) + "]";
                continue;
            }
            void *m = mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
            out += m == MAP_FAILED
                ? " mmap_syslib[" + std::string(cand) + " fail errno=" + std::to_string(errno) + "]"
                : " mmap_syslib[" + std::string(cand) + " ok]";
            if (m != MAP_FAILED) {
                munmap(m, 4096);
            }
            close(fd);
        }
    }

    // 7. dlopen from the app's own data directory: the linker maps executable segments, so this
    //    separates "we may not create exec pages" from "the linker may map our file".
    if (!dir.empty()) {
        const std::string src = DirOfSelf() + "/libnavi.so";
        const std::string dst = dir + "/probe-lib.so";
        FILE *in = fopen(src.c_str(), "re");
        bool copied = false;
        if (in != nullptr) {
            FILE *outf = fopen(dst.c_str(), "we");
            if (outf != nullptr) {
                char buf[16384];
                size_t n = 0;
                while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
                    fwrite(buf, 1, n, outf);
                }
                fclose(outf);
                copied = true;
            }
            fclose(in);
        }
        if (copied) {
            void *h = dlopen(dst.c_str(), RTLD_NOW | RTLD_LOCAL);
            out += h == nullptr
                ? " dlopen_appdir[fail " + std::string(dlerror()) + "]"
                : " dlopen_appdir[ok]";
        } else {
            out += " dlopen_appdir[copy-fail]";
        }
    }


    // 8. The app's own lib directory: can we add a library there, and can the linker map it?
    {
        const std::string dirp = DirOfSelf();
        const std::string probe = dirp + "/probe-write.so";
        FILE *f = fopen(probe.c_str(), "we");
        if (f == nullptr) {
            out += " write_libdir[fail errno=" + std::to_string(errno) + "]";
        } else {
            fputs("not a library", f);
            fclose(f);
            out += " write_libdir[ok]";
            remove(probe.c_str());
        }
        void *h = dlopen((dirp + "/libnavi.so").c_str(), RTLD_NOW | RTLD_LOCAL);
        out += h == nullptr
            ? " dlopen_libdir[fail " + std::string(dlerror()) + "]"
            : " dlopen_libdir[ok]";
    }

    // 9. Which mappings are executable right now, and where do they come from.
    {
        const std::string maps = ReadFile("/proc/self/maps");
        int exec = 0;
        int shown = 0;
        size_t at = 0;
        std::string sample;
        while (at < maps.size() && at != std::string::npos) {
            const size_t end = maps.find('\n', at);
            const std::string line = maps.substr(at, end == std::string::npos ? std::string::npos
                                                                             : end - at);
            if (line.find(" r-x") != std::string::npos || line.find(" rwx") != std::string::npos) {
                exec += 1;
                if (shown < 3) {
                    sample += "[" + line + "]";
                    shown += 1;
                }
            }
            at = end == std::string::npos ? std::string::npos : end + 1;
        }
        out += " exec_maps[count=" + std::to_string(exec) + "]";
        out += " maps_sample[" + sample + "]";
    }


    // 10. File mapping at a fixed address with PROT_EXEC.
    //
    // The plain mapping above is refused, but the address is a separate input: MAP_FIXED asks the
    // kernel to place the file's segment at the address the ELF was linked for, which is the only
    // shape a loader can use anyway.
    {
        const char *targets[] = { "libdir", "appdir" };
        for (const char *which : targets) {
            std::string path;
            if (std::string(which) == "libdir") {
                path = DirOfSelf() + "/libnavi.so";
            } else if (!dir.empty()) {
                path = dir + "/probe-toybox";
            } else {
                continue;
            }
            const int fd = open(path.c_str(), O_RDONLY);
            if (fd < 0) {
                out += " mmap_fixed_exec[" + std::string(which) + " open-fail errno=" +
                       std::to_string(errno) + "]";
                continue;
            }
            void *addr = reinterpret_cast<void *>(0x400000UL);
            void *m = mmap(addr, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_FIXED, fd, 0);
            out += m == MAP_FAILED
                ? " mmap_fixed_exec[" + std::string(which) + " fail errno=" +
                  std::to_string(errno) + "]"
                : " mmap_fixed_exec[" + std::string(which) + " ok]";
            if (m != MAP_FAILED) {
                munmap(m, 4096);
            }
            close(fd);
        }
    }


    // 11. The installed-bundle library path, mapped the way a loader does it: reserve, then cover
    // each segment at its own address with the segment's own protection.
    {
        out += " selfdir[" + DirOfSelf() + "]";
        const std::string bundle = "/data/storage/el1/bundle/libs/arm64/libnavi.so";
        const int fd = open(bundle.c_str(), O_RDONLY);
        if (fd < 0) {
            out += " mmap_bundle_lib[open-fail errno=" + std::to_string(errno) + "]";
        } else {
            struct stat stt;
            fstat(fd, &stt);
            void *reserve = mmap(nullptr, 65536, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (reserve == MAP_FAILED) {
                out += " mmap_bundle_lib[reserve-fail errno=" + std::to_string(errno) + "]";
            } else {
                const unsigned long base = reinterpret_cast<unsigned long>(reserve);
                void *seg = mmap(reinterpret_cast<void *>(base), 4096, PROT_READ | PROT_EXEC,
                                 MAP_PRIVATE | MAP_FIXED, fd, 0);
                out += seg == MAP_FAILED
                    ? " mmap_bundle_lib[seg-fail errno=" + std::to_string(errno) + "]"
                    : " mmap_bundle_lib[ok filesize=" + std::to_string(stt.st_size) + "]";
                munmap(reinterpret_cast<void *>(base), 65536);
            }
            close(fd);
        }
    }


    // 12. Which system binaries accept an exec from this domain, and what is in /system/bin.
    {
        const char *cands[] = {
            "/system/bin/sh", "/system/bin/ash", "/system/bin/busybox", "/system/bin/shell",
            "/system/bin/toybox", "/system/bin/bash", "/system/bin/python3",
            "/system/bin/ip", "/system/bin/ifconfig", "/bin/toybox"
        };
        for (const char *cand : cands) {
            out += " exec_try[" + std::string(cand) + " " + ExecOnce(cand, "--help") + "]";
        }
        DIR *d = opendir("/system/bin");
        if (d == nullptr) {
            out += " ls_system_bin[opendir-fail errno=" + std::to_string(errno) + "]";
        } else {
            int n = 0;
            std::string names;
            struct dirent *e = nullptr;
            while ((e = readdir(d)) != nullptr && n < 12) {
                names += std::string(e->d_name) + ",";
                n += 1;
            }
            closedir(d);
            out += " ls_system_bin[count=" + std::to_string(n) + " first=" + names + "]";
        }
    }


    // 13. A large blank file as a code carrier: map it writable, put code in it, ask for execute.
    //
    // The size is the point of the proposal (a big data segment to hold anything), so the file is
    // created sparse at 1 GiB; ftruncate costs no blocks. Three orders are tried on the same file:
    // map-then-ask (RW then mprotect RX), ask-at-map (RWX directly), and ask-alone (RX directly).
    if (!dir.empty()) {
        const std::string carrier = dir + "/code-carrier.bin";
        const int fd = open(carrier.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            out += " carrier[open-fail errno=" + std::to_string(errno) + "]";
        } else {
            const off_t size = static_cast<off_t>(1) << 30;
            const int trunc = ftruncate(fd, size);
            out += " carrier[size=" + std::to_string(static_cast<long long>(size)) +
                   " ftruncate=" + std::to_string(trunc) + "]";

            // Order A: writable mapping, code written, then mprotect to execute.
            void *rw = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (rw == MAP_FAILED) {
                out += " carrier_rw_then_x[mmap-fail errno=" + std::to_string(errno) + "]";
            } else {
                uint32_t *w = reinterpret_cast<uint32_t *>(rw);
                w[0] = 0x528000E0u;  // mov w0, #7
                w[1] = 0xD65F03C0u;  // ret
                const int mrc = mprotect(rw, 4096, PROT_READ | PROT_EXEC);
                const int merr = errno;
                out += " carrier_rw_then_x[mprotect=" + std::to_string(mrc) +
                       " errno=" + std::to_string(merr) + "]";
                if (mrc == 0) {
                    __builtin___clear_cache(reinterpret_cast<char *>(rw),
                                            reinterpret_cast<char *>(rw) + 8);
                    auto fn = reinterpret_cast<int (*)()>(rw);
                    out += " carrier_call[=" + std::to_string(fn()) + "]";
                }
                munmap(rw, 4096);
            }

            // Order B: ask for write and execute together, at map time.
            void *rwx = mmap(nullptr, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_SHARED, fd, 0);
            out += rwx == MAP_FAILED
                ? " carrier_rwx[fail errno=" + std::to_string(errno) + "]"
                : " carrier_rwx[ok]";
            if (rwx != MAP_FAILED) {
                munmap(rwx, 4096);
            }

            // Order C: ask for execute only, at map time.
            void *rx = mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
            out += rx == MAP_FAILED
                ? " carrier_rx[fail errno=" + std::to_string(errno) + "]"
                : " carrier_rx[ok]";
            if (rx != MAP_FAILED) {
                munmap(rx, 4096);
            }

            // Order D: reserve without access, then ask for execute on the reservation.
            void *reserved = mmap(nullptr, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (reserved != MAP_FAILED) {
                const int mrc = mprotect(reserved, 4096, PROT_READ | PROT_EXEC);
                out += " anon_none_then_x[mprotect=" + std::to_string(mrc) +
                       " errno=" + std::to_string(errno) + "]";
                munmap(reserved, 4096);
            }

            close(fd);
            remove(carrier.c_str());
        }
    }


    // 14. dlopen of a library we place ourselves.
    //
    // The linker maps a library's segments executable, so if it accepted a file we wrote, it would
    // be doing the one thing we are not allowed to do ourselves. Two questions therefore: does a
    // blank file fail differently from a real one (which separates "bad file" from "path not
    // allowed"), and does a byte-identical copy of a working library load from each writable root.
    {
        struct Root {
            const char *name;
            std::string path;
        };
        const Root roots[] = { { "files", dir }, { "cache", cache } };
        for (const Root &root : roots) {
            if (root.path.empty()) {
                out += std::string(" dlopen_") + root.name + "[no-root]";
                continue;
            }
            // A blank file first: if the path were acceptable, the linker would report an ELF
            // format error rather than a lookup failure.
            const std::string blank = root.path + "/blank.so";
            FILE *bf = fopen(blank.c_str(), "we");
            if (bf == nullptr) {
                out += std::string(" dlopen_") + root.name + "_blank[create-fail errno=" +
                       std::to_string(errno) + "]";
                continue;
            }
            fputs("not an elf", bf);
            fclose(bf);
            void *bh = dlopen(blank.c_str(), RTLD_NOW | RTLD_LOCAL);
            out += std::string(" dlopen_") + root.name + "_blank[" +
                   (bh == nullptr ? std::string(dlerror()) : std::string("ok")) + "]";
            if (bh != nullptr) {
                dlclose(bh);
            }
            // Then a real library, copied byte for byte from one the linker already accepts.
            const std::string src = DirOfSelf() + "/libnavi.so";
            const std::string copy = root.path + "/copy-real.so";
            FILE *in = fopen(src.c_str(), "re");
            if (in == nullptr) {
                out += std::string(" dlopen_") + root.name + "_real[src-open-fail]";
                continue;
            }
            FILE *outf = fopen(copy.c_str(), "we");
            if (outf == nullptr) {
                fclose(in);
                out += std::string(" dlopen_") + root.name + "_real[copy-fail errno=" +
                       std::to_string(errno) + "]";
                continue;
            }
            char buf[16384];
            size_t n = 0;
            while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
                fwrite(buf, 1, n, outf);
            }
            fclose(outf);
            fclose(in);
            struct stat cst;
            const bool present = stat(copy.c_str(), &cst) == 0;
            out += std::string(" dlopen_") + root.name + "_real[size=" +
                   std::to_string(present ? static_cast<long long>(cst.st_size) : -1) + "]";
            void *rh = dlopen(copy.c_str(), RTLD_NOW | RTLD_LOCAL);
            out += std::string(" dlopen_") + root.name + "_real[" +
                   (rh == nullptr ? std::string(dlerror()) : std::string("ok")) + "]";
            if (rh != nullptr) {
                dlclose(rh);
            }
            remove(blank.c_str());
            remove(copy.c_str());
        }
    }


    // 15. Spoofing the linker's read instead of its path check.
    //
    // The loader already maps the shipped library executable, so the question is whether its bytes
    // can be replaced through another handle: a writable shared mapping of the same inode, a direct
    // write to the file, a write through /proc/self/mem, a symlink inside the accepted directory,
    // or a path that escapes our own directory back into it.
    {
        const std::string shipped = DirOfSelf() + "/libnavi.so";

        const int rwfd = open(shipped.c_str(), O_RDWR);
        out += rwfd < 0
            ? " shipped_open_rdwr[fail errno=" + std::to_string(errno) + "]"
            : " shipped_open_rdwr[ok]";
        if (rwfd >= 0) {
            char probeByte = 0;
            const ssize_t rd = pread(rwfd, &probeByte, 1, 0);
            out += " shipped_pread[=" + std::to_string(rd) + "]";
            void *shared = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, rwfd, 0);
            if (shared == MAP_FAILED) {
                out += " shipped_mmap_shared_w[fail errno=" + std::to_string(errno) + "]";
            } else {
                volatile char *cell = reinterpret_cast<volatile char *>(shared);
                const char saved = cell[0];
                cell[0] = saved;  // a write of the same value: proves writability without damage
                out += " shipped_mmap_shared_w[ok]";
                munmap(shared, 4096);
            }
            close(rwfd);
        } else {
            out += " shipped_mmap_shared_w[skipped]";
        }

        // /proc/self/mem: a write through it patches the process's own pages, exec included.
        const int memfd = open("/proc/self/mem", O_RDWR);
        if (memfd < 0) {
            out += " selfmem_open[fail errno=" + std::to_string(errno) + "]";
        } else {
            void *self = reinterpret_cast<void *>(&SandboxProbe);
            char cellCopy = *reinterpret_cast<char *>(self);
            const ssize_t wr = pwrite(memfd, &cellCopy, 1, reinterpret_cast<off_t>(self));
            out += wr == 1 ? " selfmem_write[ok]" : " selfmem_write[fail errno=" +
                std::to_string(errno) + "]";
            close(memfd);
        }

        // A symlink inside the directory the loader accepts, pointing at a file of ours.
        if (!dir.empty()) {
            const std::string ours = dir + "/copy-real.so";
            const std::string link = DirOfSelf() + "/libspoof.so";
            const int ls = symlink(ours.c_str(), link.c_str());
            out += ls == 0
                ? " libdir_symlink[ok]"
                : " libdir_symlink[fail errno=" + std::to_string(errno) + "]";
            if (ls == 0) {
                void *h = dlopen(link.c_str(), RTLD_NOW | RTLD_LOCAL);
                out += std::string(" dlopen_symlink[") + (h == nullptr ? dlerror() : "ok") + "]";
                if (h != nullptr) {
                    dlclose(h);
                }
                remove(link.c_str());
            }
        }

        // A path that walks out of the accepted directory and back into ours.
        if (!dir.empty()) {
            const std::string escape = DirOfSelf() + "/../../../../../el2/base/haps/entry/files/copy-real.so";
            void *h = dlopen(escape.c_str(), RTLD_NOW | RTLD_LOCAL);
            out += std::string(" dlopen_escape[") + (h == nullptr ? dlerror() : "ok") + "]";
            if (h != nullptr) {
                dlclose(h);
            }
        }
    }

    // 5. seccomp filter installation: what an in-process syscall interposer would need.
    struct sock_filter allow_all[] = {
        { 0x06, 0, 0, 0x7fff0000u }  // BPF_RET | BPF_K, SECCOMP_RET_ALLOW
    };
    struct sock_fprog prog;
    prog.len = 1;
    prog.filter = allow_all;
    const int sec = prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0, 0);
    out += " prctl_seccomp[rc=" + std::to_string(sec) + " errno=" + std::to_string(errno) + "]";

    napi_value r = nullptr;
    napi_create_string_utf8(env, out.c_str(), out.size(), &r);
    return r;
}


// One interpreter state per process: `cd` persists across calls, which is what makes a sequence of
// commands behave like a session instead of a series of one-shot invocations.
static ShellState gShell;
static bool gShellReady = false;

napi_value SandboxSh(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string line;
    std::string root;
    if (argc > 0 && argv[0] != nullptr) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
        line.assign(len, '\0');
        napi_get_value_string_utf8(env, argv[0], &line[0], len + 1, &len);
    }
    if (argc > 1 && argv[1] != nullptr) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[1], nullptr, 0, &len);
        root.assign(len, '\0');
        napi_get_value_string_utf8(env, argv[1], &root[0], len + 1, &len);
    }
    if (!gShellReady) {
        gShell.cwd = root.empty() ? std::string("/") : root;
        gShellReady = true;
    }
    const std::string out = SandboxShellRun(line, gShell);
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), out.size(), &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "buildInProc", nullptr, Build, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "hvoltCall", nullptr, HvoltCall, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "execProbe", nullptr, ExecProbe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sandboxProbe", nullptr, SandboxProbe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sandboxSh", nullptr, SandboxSh, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamStart", nullptr, StreamStart, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamRead", nullptr, StreamRead, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamStop", nullptr, StreamStop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamNext", nullptr, StreamNext, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, 10, desc);
    return exports;
}
}  // namespace

static napi_module naviModule = {
    1, 0, nullptr, Init, "navi", nullptr, { 0 },
};

extern "C" __attribute__((constructor)) void RegisterNavi(void)
{
    napi_module_register(&naviModule);
}

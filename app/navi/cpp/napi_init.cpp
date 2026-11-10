#include <dlfcn.h>
#include <string>
#include "napi/native_api.h"

#include <sys/stat.h>
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

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "buildInProc", nullptr, Build, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "hvoltCall", nullptr, HvoltCall, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "execProbe", nullptr, ExecProbe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamStart", nullptr, StreamStart, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamRead", nullptr, StreamRead, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamStop", nullptr, StreamStop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "streamNext", nullptr, StreamNext, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, 8, desc);
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

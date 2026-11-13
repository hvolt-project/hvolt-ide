// Runs the same sandbox questions inside a native child process.
//
// The child is created by the ability through childProcessManager, so it is a separate process
// with its own SELinux domain. Whether that domain is subject to the same executable-memory policy
// is a question only this process can answer, so it answers it and logs the result.

#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>

#include <hilog/log.h>

namespace {

std::string ReadLine(const char *path)
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

void Probe()
{
    std::string out;
    out += "child domain=" + ReadLine("/proc/self/attr/current");
    out += " pid=" + std::to_string(getpid());

    void *rwx = mmap(nullptr, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    out += rwx == MAP_FAILED
        ? " mmap_rwx[fail errno=" + std::to_string(errno) + "]"
        : " mmap_rwx[ok]";
    if (rwx != MAP_FAILED) {
        munmap(rwx, 4096);
    }

    void *exec_only = mmap(nullptr, 4096, PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    out += exec_only == MAP_FAILED
        ? " mmap_exec[fail errno=" + std::to_string(errno) + "]"
        : " mmap_exec[ok]";
    if (exec_only != MAP_FAILED) {
        munmap(exec_only, 4096);
    }

    const std::string lib = "/data/storage/el1/bundle/libs/arm64/libnavi.so";
    const int fd = open(lib.c_str(), O_RDONLY);
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

    struct sock_filter allow_all[] = { { 0x06, 0, 0, 0x7fff0000u } };
    struct sock_fprog prog;
    prog.len = 1;
    prog.filter = allow_all;
    const int sec = prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0, 0);
    out += " prctl_seccomp[rc=" + std::to_string(sec) + " errno=" + std::to_string(errno) + "]";

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "childProbe", "%{public}s", out.c_str());
    sync();
}

}  // namespace

// The symbol the framework looks up to establish the connection. Returning nullptr reports that no
// IPC stub exists, which is correct: this child exists only to be measured.
extern "C" void *NativeChildProcess_OnConnect()
{
    Probe();
    return nullptr;
}

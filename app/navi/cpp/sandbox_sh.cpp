// A shell that runs inside the application's own sandbox.
//
// The device shell (`hvolt shell`) can read this sandbox but cannot write or delete inside it, so
// it cannot change the application's own files. This interpreter exists for exactly that gap: it
// dispatches commands directly against the sandbox with ordinary POSIX calls, in the application's
// own process, where those permissions do exist.
//
// It deliberately does not execute anything. Every command is implemented here; there is no
// fork/exec path, which is also why it works under the platform's executable-memory policy.

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sandbox_sh.h"

namespace {

// Splits a command line into words. Double and single quotes group; a backslash escapes the next
// character outside single quotes. Unbalanced quotes consume the rest of the line, which is what a
// shell does with an unfinished quote at end of input.
std::vector<std::string> SplitWords(const std::string &line)
{
    std::vector<std::string> words;
    std::string current;
    bool inWord = false;
    char quote = 0;
    for (size_t i = 0; i < line.size(); i += 1) {
        const char c = line[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (c == '\\' && quote == '"' && i + 1 < line.size()) {
                i += 1;
                current += line[i];
            } else {
                current += c;
            }
            continue;
        }
        if (c == '\'' || c == '"') {
            quote = c;
            inWord = true;
            continue;
        }
        if (c == '\\' && i + 1 < line.size()) {
            i += 1;
            current += line[i];
            inWord = true;
            continue;
        }
        if (c == ' ' || c == '\t') {
            if (inWord) {
                words.push_back(current);
                current.clear();
                inWord = false;
            }
            continue;
        }
        current += c;
        inWord = true;
    }
    if (inWord || !current.empty()) {
        words.push_back(current);
    }
    return words;
}

std::string Join(const std::vector<std::string> &items, size_t from)
{
    std::string out;
    for (size_t i = from; i < items.size(); i += 1) {
        if (i > from) {
            out += ' ';
        }
        out += items[i];
    }
    return out;
}

bool IsDirectory(const std::string &path)
{
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

std::string TrimSlash(const std::string &path)
{
    std::string out = path;
    while (out.size() > 1 && out.back() == '/') {
        out.pop_back();
    }
    return out;
}

// Resolves a path against the working directory. Absolute paths and `..` are left to the kernel:
// this interpreter is confined by the application's own sandbox, not by string rules here.
std::string Resolve(const std::string &cwd, const std::string &arg)
{
    if (arg.empty()) {
        return cwd;
    }
    if (arg[0] == '/') {
        return TrimSlash(arg);
    }
    if (cwd == "/") {
        return TrimSlash("/" + arg);
    }
    return TrimSlash(cwd + "/" + arg);
}

std::string ReadAll(const std::string &path, bool *ok)
{
    FILE *f = fopen(path.c_str(), "re");
    if (f == nullptr) {
        *ok = false;
        return std::string();
    }
    std::string out;
    char buf[8192];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        out.append(buf, n);
    }
    fclose(f);
    *ok = true;
    return out;
}

bool WriteAll(const std::string &path, const std::string &body, bool append)
{
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644);
    if (fd < 0) {
        return false;
    }
    size_t written = 0;
    while (written < body.size()) {
        const ssize_t n = write(fd, body.data() + written, body.size() - written);
        if (n <= 0) {
            close(fd);
            return false;
        }
        written += static_cast<size_t>(n);
    }
    close(fd);
    return true;
}

bool RemoveTree(const std::string &path, int depth)
{
    if (depth > 32) {
        return false;
    }
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) {
        return false;
    }
    if (!S_ISDIR(st.st_mode)) {
        return remove(path.c_str()) == 0;
    }
    DIR *d = opendir(path.c_str());
    if (d == nullptr) {
        return false;
    }
    bool ok = true;
    struct dirent *e = nullptr;
    while ((e = readdir(d)) != nullptr) {
        const std::string name(e->d_name);
        if (name == "." || name == "..") {
            continue;
        }
        if (!RemoveTree(path + "/" + name, depth + 1)) {
            ok = false;
        }
    }
    closedir(d);
    if (!ok) {
        return false;
    }
    return rmdir(path.c_str()) == 0;
}

// One line of `ls -l`, close enough to the usual shape to be read by eye or by grep.
std::string DescribeEntry(const std::string &dir, const char *name)
{
    const std::string full = dir + "/" + name;
    struct stat st;
    if (lstat(full.c_str(), &st) != 0) {
        return std::string();
    }
    char head = '-';
    if (S_ISDIR(st.st_mode)) {
        head = 'd';
    } else if (S_ISLNK(st.st_mode)) {
        head = 'l';
    }
    char mode[11] = { 0 };
    snprintf(mode, sizeof(mode), "%c%c%c%c%c%c%c%c%c%c", head,
             (st.st_mode & S_IRUSR) ? 'r' : '-', (st.st_mode & S_IWUSR) ? 'w' : '-',
             (st.st_mode & S_IXUSR) ? 'x' : '-', (st.st_mode & S_IRGRP) ? 'r' : '-',
             (st.st_mode & S_IWGRP) ? 'w' : '-', (st.st_mode & S_IXGRP) ? 'x' : '-',
             (st.st_mode & S_IROTH) ? 'r' : '-', (st.st_mode & S_IWOTH) ? 'w' : '-',
             (st.st_mode & S_IXOTH) ? 'x' : '-');
    char line[512];
    snprintf(line, sizeof(line), "%s %10lld %s\n", mode, static_cast<long long>(st.st_size), name);
    return std::string(line);
}

// Returns the exit status and appends output to `out`. Every command is dispatched here; an
// unknown word is an error rather than a program to run.
int Dispatch(ShellState &state, const std::vector<std::string> &argv, std::string &out)
{
    const std::string &cmd = argv[0];

    if (cmd == "pwd") {
        out += state.cwd + "\n";
        return 0;
    }

    if (cmd == "cd") {
        const std::string target = Resolve(state.cwd, argv.size() > 1 ? argv[1] : "/");
        if (!IsDirectory(target)) {
            state.lastError = "cd: not a directory: " + target;
            return 1;
        }
        // `cwd` is reported relative to the sandbox root, which is the only root that exists here.
        state.cwd = target;
        return 0;
    }

    if (cmd == "ls") {
        bool longForm = false;
        std::vector<std::string> paths;
        for (size_t i = 1; i < argv.size(); i += 1) {
            if (argv[i] == "-l" || argv[i] == "-la" || argv[i] == "-al") {
                longForm = true;
            } else if (argv[i] == "-a") {
                longForm = false;
            } else {
                paths.push_back(argv[i]);
            }
        }
        if (paths.empty()) {
            paths.push_back(".");
        }
        int status = 0;
        for (const std::string &raw : paths) {
            const std::string path = Resolve(state.cwd, raw);
            struct stat st;
            if (stat(path.c_str(), &st) != 0) {
                state.lastError = "ls: no such path: " + path;
                status = 1;
                continue;
            }
            if (!S_ISDIR(st.st_mode)) {
                out += longForm ? DescribeEntry(state.cwd, raw.c_str()) : raw + "\n";
                continue;
            }
            DIR *d = opendir(path.c_str());
            if (d == nullptr) {
                state.lastError = "ls: cannot open: " + path;
                status = 1;
                continue;
            }
            std::vector<std::string> names;
            struct dirent *e = nullptr;
            while ((e = readdir(d)) != nullptr) {
                const std::string name(e->d_name);
                if (name != "." && name != "..") {
                    names.push_back(name);
                }
            }
            closedir(d);
            for (size_t i = 0; i + 1 < names.size(); i += 1) {
                for (size_t j = i + 1; j < names.size(); j += 1) {
                    if (names[j] < names[i]) {
                        const std::string tmp = names[i];
                        names[i] = names[j];
                        names[j] = tmp;
                    }
                }
            }
            for (const std::string &name : names) {
                out += longForm ? DescribeEntry(path, name.c_str()) : name + "\n";
            }
        }
        return status;
    }

    if (cmd == "cat") {
        if (argv.size() < 2) {
            state.lastError = "cat: missing path";
            return 1;
        }
        int status = 0;
        for (size_t i = 1; i < argv.size(); i += 1) {
            bool ok = false;
            const std::string body = ReadAll(Resolve(state.cwd, argv[i]), &ok);
            if (!ok) {
                state.lastError = "cat: cannot read: " + argv[i];
                status = 1;
                continue;
            }
            out += body;
        }
        return status;
    }

    if (cmd == "mkdir") {
        if (argv.size() < 2) {
            state.lastError = "mkdir: missing path";
            return 1;
        }
        bool parents = false;
        std::string target;
        for (size_t i = 1; i < argv.size(); i += 1) {
            if (argv[i] == "-p") {
                parents = true;
            } else {
                target = argv[i];
            }
        }
        const std::string path = Resolve(state.cwd, target);
        if (parents) {
            std::string built;
            size_t at = 0;
            if (!path.empty() && path[0] == '/') {
                built = "/";
                at = 1;
            }
            while (at <= path.size()) {
                const size_t next = path.find('/', at);
                const std::string part = path.substr(at, next == std::string::npos
                                                         ? std::string::npos
                                                         : next - at);
                if (!part.empty()) {
                    built += (built.size() > 1 || built.empty()) ? "" : "";
                    // `built` is empty for a relative first segment; back() on it is undefined.
                    if (!built.empty() && built.back() != '/') {
                        built += '/';
                    }
                    built += part;
                    mkdir(built.c_str(), 0755);
                }
                if (next == std::string::npos) {
                    break;
                }
                at = next + 1;
            }
            return IsDirectory(path) ? 0 : 1;
        }
        const int rc = mkdir(path.c_str(), 0755);
        if (rc != 0) {
            state.lastError = "mkdir: " + path + ": errno=" + std::to_string(errno);
        }
        return rc == 0 ? 0 : 1;
    }

    if (cmd == "rm") {
        bool recursive = false;
        bool force = false;
        std::vector<std::string> paths;
        for (size_t i = 1; i < argv.size(); i += 1) {
            if (argv[i] == "-r" || argv[i] == "-rf" || argv[i] == "-fr") {
                recursive = true;
            } else if (argv[i] == "-f") {
                force = true;
            } else {
                paths.push_back(argv[i]);
            }
        }
        if (paths.empty()) {
            state.lastError = "rm: missing path";
            return 1;
        }
        int status = 0;
        for (const std::string &raw : paths) {
            const std::string path = Resolve(state.cwd, raw);
            struct stat st;
            if (lstat(path.c_str(), &st) != 0) {
                if (!force) {
                    state.lastError = "rm: no such path: " + path;
                    status = 1;
                }
                continue;
            }
            const bool done = S_ISDIR(st.st_mode) && recursive ? RemoveTree(path, 0)
                                                               : remove(path.c_str()) == 0;
            if (!done) {
                state.lastError = "rm: failed: " + path + ": errno=" + std::to_string(errno);
                status = 1;
            }
        }
        return status;
    }

    if (cmd == "cp" || cmd == "mv") {
        if (argv.size() < 3) {
            state.lastError = cmd + ": needs source and destination";
            return 1;
        }
        const std::string from = Resolve(state.cwd, argv[1]);
        std::string to = Resolve(state.cwd, argv[2]);
        if (IsDirectory(to)) {
            const std::string base = argv[1].substr(argv[1].find_last_of('/') + 1);
            to = TrimSlash(to + "/" + base);
        }
        if (cmd == "mv") {
            if (rename(from.c_str(), to.c_str()) != 0) {
                state.lastError = "mv: " + from + " -> " + to + ": errno=" +
                                  std::to_string(errno);
                return 1;
            }
            return 0;
        }
        bool ok = false;
        const std::string body = ReadAll(from, &ok);
        if (!ok) {
            state.lastError = "cp: cannot read: " + from;
            return 1;
        }
        if (!WriteAll(to, body, false)) {
            state.lastError = "cp: cannot write: " + to;
            return 1;
        }
        return 0;
    }

    if (cmd == "touch") {
        if (argv.size() < 2) {
            state.lastError = "touch: missing path";
            return 1;
        }
        const std::string path = Resolve(state.cwd, argv[1]);
        return WriteAll(path, std::string(), true) ? 0 : 1;
    }

    if (cmd == "stat") {
        if (argv.size() < 2) {
            state.lastError = "stat: missing path";
            return 1;
        }
        const std::string path = Resolve(state.cwd, argv[1]);
        struct stat st;
        if (stat(path.c_str(), &st) != 0) {
            state.lastError = "stat: no such path: " + path;
            return 1;
        }
        out += "path " + path + "\n";
        out += "size " + std::to_string(static_cast<long long>(st.st_size)) + "\n";
        out += std::string("type ") + (S_ISDIR(st.st_mode) ? "dir" : "file") + "\n";
        out += "mode " + std::to_string(static_cast<unsigned>(st.st_mode & 07777)) + "\n";
        return 0;
    }

    if (cmd == "wc") {
        if (argv.size() < 2) {
            state.lastError = "wc: missing path";
            return 1;
        }
        bool ok = false;
        const std::string body = ReadAll(Resolve(state.cwd, argv[1]), &ok);
        if (!ok) {
            state.lastError = "wc: cannot read: " + argv[1];
            return 1;
        }
        size_t lines = 0;
        for (char c : body) {
            if (c == '\n') {
                lines += 1;
            }
        }
        out += std::to_string(lines) + " " + std::to_string(body.size()) + " " + argv[1] + "\n";
        return 0;
    }

    if (cmd == "head" || cmd == "tail") {
        size_t count = 10;
        std::string path;
        for (size_t i = 1; i < argv.size(); i += 1) {
            if (argv[i] == "-n" && i + 1 < argv.size()) {
                count = static_cast<size_t>(atoi(argv[i + 1].c_str()));
                i += 1;
            } else {
                path = argv[i];
            }
        }
        if (path.empty()) {
            state.lastError = cmd + ": missing path";
            return 1;
        }
        bool ok = false;
        const std::string body = ReadAll(Resolve(state.cwd, path), &ok);
        if (!ok) {
            state.lastError = cmd + ": cannot read: " + path;
            return 1;
        }
        std::vector<std::string> lines;
        size_t at = 0;
        while (at <= body.size()) {
            const size_t end = body.find('\n', at);
            const std::string line = body.substr(at, end == std::string::npos
                                                         ? std::string::npos
                                                         : end - at);
            if (!line.empty() || end != std::string::npos) {
                lines.push_back(line);
            }
            if (end == std::string::npos) {
                break;
            }
            at = end + 1;
        }
        if (cmd == "head") {
            for (size_t i = 0; i < lines.size() && i < count; i += 1) {
                out += lines[i] + "\n";
            }
        } else {
            const size_t start = lines.size() > count ? lines.size() - count : 0;
            for (size_t i = start; i < lines.size(); i += 1) {
                out += lines[i] + "\n";
            }
        }
        return 0;
    }

    if (cmd == "grep") {
        bool ignoreCase = false;
        std::string needle;
        std::vector<std::string> paths;
        for (size_t i = 1; i < argv.size(); i += 1) {
            if (argv[i] == "-i") {
                ignoreCase = true;
            } else if (needle.empty()) {
                needle = argv[i];
            } else {
                paths.push_back(argv[i]);
            }
        }
        if (needle.empty()) {
            state.lastError = "grep: missing pattern";
            return 1;
        }
        std::string lowered = needle;
        if (ignoreCase) {
            for (char &c : lowered) {
                c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
            }
        }
        int found = 0;
        for (const std::string &raw : paths) {
            bool ok = false;
            const std::string body = ReadAll(Resolve(state.cwd, raw), &ok);
            if (!ok) {
                state.lastError = "grep: cannot read: " + raw;
                continue;
            }
            std::string candidate = body;
            if (ignoreCase) {
                for (char &c : candidate) {
                    c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
                }
            }
            if (candidate.find(lowered) != std::string::npos) {
                out += raw + ": " + needle + "\n";
                found += 1;
            }
        }
        return found > 0 ? 0 : 1;
    }

    if (cmd == "echo") {
        out += Join(argv, argv.size() > 1 && argv[1] == "-n" ? 2 : 1);
        if (!(argv.size() > 1 && argv[1] == "-n")) {
            out += "\n";
        }
        return 0;
    }

    if (cmd == "write") {
        // Not a POSIX command: it exists because the agent's most common sandbox action is putting
        // exact bytes into a file, and a here-document is not worth implementing in this parser.
        if (argv.size() < 3) {
            state.lastError = "write: needs path and text";
            return 1;
        }
        const std::string path = Resolve(state.cwd, argv[1]);
        const std::string body = Join(argv, 2);
        if (!WriteAll(path, body, false)) {
            state.lastError = "write: failed: " + path;
            return 1;
        }
        return 0;
    }

    if (cmd == "find") {
        const std::string root = Resolve(state.cwd, argv.size() > 1 ? argv[1] : ".");
        std::string pattern = argv.size() > 2 ? argv[2] : "";
        std::vector<std::string> stackOne;
        stackOne.push_back(root);
        while (!stackOne.empty()) {
            const std::string path = stackOne.back();
            stackOne.pop_back();
            DIR *d = opendir(path.c_str());
            if (d == nullptr) {
                continue;
            }
            struct dirent *e = nullptr;
            while ((e = readdir(d)) != nullptr) {
                const std::string name(e->d_name);
                if (name == "." || name == "..") {
                    continue;
                }
                const std::string full = path + "/" + name;
                if (pattern.empty() || name.find(pattern) != std::string::npos) {
                    out += full + "\n";
                }
                if (IsDirectory(full)) {
                    stackOne.push_back(full);
                }
            }
            closedir(d);
        }
        return 0;
    }

    state.lastError = "unknown command: " + cmd + "（这里的每条命令都在包内实现，不执行外部程序）";
    return 127;
}

}  // namespace

// Runs one command line against the sandbox. `cwd` is the interpreter's working directory and is
// reported back so the caller can keep it between calls.
std::string SandboxShellRun(const std::string &line, ShellState &state)
{
    std::vector<std::string> words = SplitWords(line);
    std::string out;
    if (words.empty()) {
        return R"({"code":0,"out":"","cwd":")" + state.cwd + R"("})";
    }
    const int code = Dispatch(state, words, out);
    std::string escaped;
    for (char c : out) {
        switch (c) {
            case '"': escaped += "\\\""; break;
            case '\\': escaped += "\\\\"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default: escaped += c;
        }
    }
    std::string errEscaped;
    for (char c : state.lastError) {
        if (c == '"') {
            errEscaped += "\\\"";
        } else if (c == '\\') {
            errEscaped += "\\\\";
        } else if (c == '\n') {
            errEscaped += "\\n";
        } else {
            errEscaped += c;
        }
    }
    state.lastError.clear();
    return "{\"code\":" + std::to_string(code) + ",\"out\":\"" + escaped + "\",\"err\":\"" +
           errEscaped + "\",\"cwd\":\"" + state.cwd + "\"}";
}

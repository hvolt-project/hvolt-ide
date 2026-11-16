// ssh：设备侧的 ssh 客户端，独立成一个能力 so。
//
// 与 libnavi.so 分开编：libssh2 与 mbedTLS 只有这个能力用到，链进主 so 会让每个不碰 ssh 的
// 工具都背着 2.5 MB 的静态库。主 so 通过 dlopen 按需加载本模块，缺它时只有 ssh 工具不可用。
//
// 会话是 handle 模式：open 建立连接并返回一个句柄，exec 拿句柄复用同一条连接，close 断开。
// 同一会话内反复 exec 不该重复握手。

#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <cstring>
#include <cstdio>
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <cerrno>
#include <sys/time.h>
#include <thread>
#include <atomic>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <napi/native_api.h>
#include <hilog/log.h>

namespace {

std::string JsonEscape(const std::string &in)
{
    std::string out;
    out.reserve(in.size() + 8);
    for (char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

std::string ArgString(napi_env env, napi_value value)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok || len == 0) {
        return std::string();
    }
    std::vector<char> buf(len + 1, 0);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &copied) != napi_ok) {
        return std::string();
    }
    return std::string(buf.data(), copied);
}

napi_value MakeString(napi_env env, const std::string &text)
{
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

/** 一条已建立的连接。socket 与 session 同生共死。 */
struct Connection {
    int sock = -1;
    LIBSSH2_SESSION *session = nullptr;
    std::string host;
    int port = 22;
    /// Guards this connection's ssh session. The table lock must not be held across IO: a
    /// slow or dead peer would then block every other handle.
    std::mutex io;
};

/** A blocking connect has no deadline of its own; this bounds how long an unreachable host
 *  can hold a tool call before it reports failure. */
constexpr int kConnectTimeoutMs = 8000;
/** Session reads and writes are bounded too, so a half-open peer cannot park a call forever. */
constexpr int kIoTimeoutSeconds = 30;
/** Idle keepalive interval; libssh2 probes once per interval while the link is quiet. */
constexpr int kKeepaliveSeconds = 30;

std::map<int, std::shared_ptr<Connection>> g_connections;
int g_nextHandle = 1;
std::mutex g_lock;

/** 连到一个 host:port，返回 socket；失败返回 -1。 */
int dial(const std::string &host, int port, std::string &error)
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portText[16];
    snprintf(portText, sizeof(portText), "%d", port);
    struct addrinfo *found = nullptr;
    int rc = getaddrinfo(host.c_str(), portText, &hints, &found);
    if (rc != 0 || found == nullptr) {
        error = std::string("resolve failed: ") + gai_strerror(rc);
        return -1;
    }
    int sock = -1;
    for (struct addrinfo *it = found; it != nullptr; it = it->ai_next) {
        int candidate = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (candidate < 0) {
            continue;
        }
        // Connect non-blocking under a poll deadline, then restore the original flags: a plain
        // connect() against an unreachable host sits in SYN retries and the caller sees a hang.
        int flags = fcntl(candidate, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(candidate, F_SETFL, flags | O_NONBLOCK);
        }
        int rc = connect(candidate, it->ai_addr, it->ai_addrlen);
        bool connected = (rc == 0);
        if (!connected && errno == EINPROGRESS) {
            struct pollfd wait;
            wait.fd = candidate;
            wait.events = POLLOUT;
            wait.revents = 0;
            if (poll(&wait, 1, kConnectTimeoutMs) > 0) {
                int soError = 0;
                socklen_t len = sizeof(soError);
                if (getsockopt(candidate, SOL_SOCKET, SO_ERROR, &soError, &len) == 0) {
                    connected = (soError == 0);
                }
            }
        }
        if (flags >= 0) {
            fcntl(candidate, F_SETFL, flags);
        }
        if (!connected) {
            close(candidate);
            continue;
        }
        struct timeval io;
        io.tv_sec = kIoTimeoutSeconds;
        io.tv_usec = 0;
        setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
        setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));
        sock = candidate;
        break;
    }
    freeaddrinfo(found);
    if (sock < 0) {
        error = "connect failed";
        return -1;
    }
    return sock;
}

/** libssh2 的错误串，带上它自己的错误码。 */
std::string LastError(LIBSSH2_SESSION *session, const char *fallback)
{
    if (session == nullptr) {
        return fallback;
    }
    char *message = nullptr;
    int len = 0;
    libssh2_session_last_error(session, &message, &len, 0);
    if (message == nullptr || len == 0) {
        return fallback;
    }
    return std::string(message, len);
}

/** 把 host key 的 SHA256 指纹算成 base64，与 OpenSSH 的 known_hosts 同格式。 */
std::string HostKeyFingerprint(LIBSSH2_SESSION *session)
{
    size_t len = 0;
    const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (hash == nullptr) {
        return std::string();
    }
    len = 32;
    static const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    for (size_t i = 0; i < len; i += 3) {
        unsigned int chunk = static_cast<unsigned char>(hash[i]) << 16;
        if (i + 1 < len) {
            chunk |= static_cast<unsigned char>(hash[i + 1]) << 8;
        }
        if (i + 2 < len) {
            chunk |= static_cast<unsigned char>(hash[i + 2]);
        }
        out += alphabet[(chunk >> 18) & 0x3F];
        out += alphabet[(chunk >> 12) & 0x3F];
        out += (i + 1 < len) ? alphabet[(chunk >> 6) & 0x3F] : '=';
        out += (i + 2 < len) ? alphabet[chunk & 0x3F] : '=';
    }
    return std::string("SHA256:") + out;
}

// --- op=open -------------------------------------------------------------------------------
// 参数：host, port, user, 然后是认证方式三选一：password / 私钥路径 + 公钥路径。
// host key 由调用方核对：返回指纹，是否接受由 ArkTS 侧的 TOFU 决定。
std::string SshOpen(const std::string &host, int port, const std::string &user,
    const std::string &password, const std::string &keyPath, const std::string &pubKeyPath,
    bool confirmOnly)
{
    std::string error;
    int sock = dial(host, port, error);
    if (sock < 0) {
        return std::string("{\"error\":\"") + JsonEscape(host + ": " + error) + "\"}";
    }
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == nullptr) {
        close(sock);
        return std::string("{\"error\":\"session init failed\"}");
    }
    libssh2_session_set_blocking(session, 1);
    // Keep the connection alive across idle periods: a NAT or firewall drops an idle TCP
    // session silently, and the next exec then fails inside libssh2 with no explanation. The
    // reply is wanted, so a dead peer is detected here instead of at the next tool call.
    libssh2_keepalive_config(session, 1, kKeepaliveSeconds);
    if (libssh2_session_handshake(session, sock) != 0) {
        std::string message = LastError(session, "handshake failed");
        libssh2_session_free(session);
        close(sock);
        return std::string("{\"error\":\"") + JsonEscape(message) + "\"}";
    }
    const std::string fingerprint = HostKeyFingerprint(session);
    // confirmOnly：只握手取指纹，认证与后续由调用方决定。TOFU 的首次确认走这一趟。
    if (confirmOnly) {
        libssh2_session_disconnect(session, "fingerprint only");
        libssh2_session_free(session);
        close(sock);
        return std::string("{\"fingerprint\":\"") + JsonEscape(fingerprint) + "\"}";
    }
    int auth = -1;
    if (!password.empty()) {
        auth = libssh2_userauth_password(session, user.c_str(), password.c_str());
    } else if (!keyPath.empty()) {
        auth = libssh2_userauth_publickey_fromfile(session, user.c_str(),
            pubKeyPath.empty() ? nullptr : pubKeyPath.c_str(), keyPath.c_str(), nullptr);
    } else {
        libssh2_session_disconnect(session, "no credentials");
        libssh2_session_free(session);
        close(sock);
        return std::string("{\"error\":\"no credentials given\"}");
    }
    if (auth != 0) {
        std::string message = LastError(session, "authentication failed");
        libssh2_session_disconnect(session, "auth failed");
        libssh2_session_free(session);
        close(sock);
        return std::string("{\"error\":\"") + JsonEscape(message) + "\",\"fingerprint\":\""
            + JsonEscape(fingerprint) + "\"}";
    }
    std::shared_ptr<Connection> conn = std::make_shared<Connection>();
    conn->sock = sock;
    conn->session = session;
    conn->host = host;
    conn->port = port;
    int handle = 0;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        handle = g_nextHandle++;
        g_connections[handle] = conn;
    }
    return std::string("{\"handle\":") + std::to_string(handle) + ",\"fingerprint\":\""
        + JsonEscape(fingerprint) + "\",\"host\":\"" + JsonEscape(host) + "\"}";
}

// --- op=exec -------------------------------------------------------------------------------
// 在已有连接上开一个 channel 执行一条命令，读到 EOF 后关 channel。
std::string SshExec(int handle, const std::string &command)
{
    std::shared_ptr<Connection> conn;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_connections.find(handle);
        if (it == g_connections.end()) {
            return std::string("{\"error\":\"no such handle\"}");
        }
        conn = it->second;
    }
    std::lock_guard<std::mutex> ioLock(conn->io);
    LIBSSH2_SESSION *session = conn->session;
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
    if (channel == nullptr) {
        return std::string("{\"error\":\"") + JsonEscape(LastError(session, "channel open failed")) + "\"}";
    }
    if (libssh2_channel_exec(channel, command.c_str()) != 0) {
        std::string message = LastError(session, "exec failed");
        libssh2_channel_free(channel);
        return std::string("{\"error\":\"") + JsonEscape(message) + "\"}";
    }
    std::string stdoutText;
    char buffer[8192];
    for (;;) {
        ssize_t got = libssh2_channel_read(channel, buffer, sizeof(buffer));
        if (got > 0) {
            stdoutText.append(buffer, static_cast<size_t>(got));
            if (stdoutText.size() > 512 * 1024) {
                stdoutText += "\n... (truncated at 512 KB)\n";
                break;
            }
            continue;
        }
        if (got == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        break;
    }
    std::string stderrText;
    for (;;) {
        ssize_t got = libssh2_channel_read_stderr(channel, buffer, sizeof(buffer));
        if (got > 0) {
            stderrText.append(buffer, static_cast<size_t>(got));
            continue;
        }
        if (got == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        break;
    }
    int exitCode = 0;
    libssh2_channel_close(channel);
    exitCode = libssh2_channel_get_exit_status(channel);
    libssh2_channel_free(channel);
    return std::string("{\"exit\":") + std::to_string(exitCode) + ",\"stdout\":\""
        + JsonEscape(stdoutText) + "\",\"stderr\":\"" + JsonEscape(stderrText) + "\"}";
}

std::string SshClose(int handle)
{
    std::shared_ptr<Connection> conn;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_connections.find(handle);
        if (it == g_connections.end()) {
            return std::string("{\"error\":\"no such handle\"}");
        }
        conn = it->second;
        // Removed before the teardown below: a concurrent lookup must not see an entry whose
        // session is being freed.
        g_connections.erase(it);
    }
    std::lock_guard<std::mutex> ioLock(conn->io);
    if (conn->session != nullptr) {
        libssh2_session_disconnect(conn->session, "bye");
        libssh2_session_free(conn->session);
    }
    if (conn->sock >= 0) {
        close(conn->sock);
    }
    return std::string("{\"closed\":") + std::to_string(handle) + "}";
}


// --- SFTP -----------------------------------------------------------------------------------
// 同一 handle 上的 sftp 子系统。每条命令自己 init/关机，不常驻：SFTP 的会话状态（打开的
// 文件、目录游标）留在调用内，跨调用不保留，这样 handle 只需要管连接。

std::string SftpRead(int handle, const std::string &path)
{
    std::shared_ptr<Connection> conn;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_connections.find(handle);
        if (it == g_connections.end()) {
            return std::string("{\"error\":\"no such handle\"}");
        }
        conn = it->second;
    }
    std::lock_guard<std::mutex> ioLock(conn->io);
    LIBSSH2_SESSION *session = conn->session;
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
    if (sftp == nullptr) {
        return std::string("{\"error\":\"") + JsonEscape(LastError(session, "sftp init failed")) + "\"}";
    }
    LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(sftp, path.c_str(), LIBSSH2_FXF_READ, 0);
    if (file == nullptr) {
        std::string message = LastError(session, "sftp open failed");
        libssh2_sftp_shutdown(sftp);
        return std::string("{\"error\":\"") + JsonEscape(message) + "\"}";
    }
    std::string text;
    char buffer[8192];
    for (;;) {
        ssize_t got = libssh2_sftp_read(file, buffer, sizeof(buffer));
        if (got > 0) {
            text.append(buffer, static_cast<size_t>(got));
            if (text.size() > 512 * 1024) {
                text += "\n... (truncated at 512 KB)\n";
                break;
            }
            continue;
        }
        if (got == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        break;
    }
    libssh2_sftp_close(file);
    libssh2_sftp_shutdown(sftp);
    return std::string("{\"text\":\"") + JsonEscape(text) + "\",\"bytes\":"
        + std::to_string(text.size()) + "}";
}

std::string SftpWrite(int handle, const std::string &path, const std::string &text)
{
    std::shared_ptr<Connection> conn;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_connections.find(handle);
        if (it == g_connections.end()) {
            return std::string("{\"error\":\"no such handle\"}");
        }
        conn = it->second;
    }
    std::lock_guard<std::mutex> ioLock(conn->io);
    LIBSSH2_SESSION *session = conn->session;
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
    if (sftp == nullptr) {
        return std::string("{\"error\":\"") + JsonEscape(LastError(session, "sftp init failed")) + "\"}";
    }
    LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(sftp, path.c_str(),
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
    if (file == nullptr) {
        std::string message = LastError(session, "sftp open failed");
        libssh2_sftp_shutdown(sftp);
        return std::string("{\"error\":\"") + JsonEscape(message) + "\"}";
    }
    size_t written = 0;
    while (written < text.size()) {
        ssize_t put = libssh2_sftp_write(file, text.c_str() + written, text.size() - written);
        if (put > 0) {
            written += static_cast<size_t>(put);
            continue;
        }
        if (put == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        break;
    }
    libssh2_sftp_close(file);
    libssh2_sftp_shutdown(sftp);
    return std::string("{\"bytes\":") + std::to_string(written) + "}";
}

std::string SftpList(int handle, const std::string &path)
{
    std::shared_ptr<Connection> conn;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_connections.find(handle);
        if (it == g_connections.end()) {
            return std::string("{\"error\":\"no such handle\"}");
        }
        conn = it->second;
    }
    std::lock_guard<std::mutex> ioLock(conn->io);
    LIBSSH2_SESSION *session = conn->session;
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
    if (sftp == nullptr) {
        return std::string("{\"error\":\"") + JsonEscape(LastError(session, "sftp init failed")) + "\"}";
    }
    LIBSSH2_SFTP_HANDLE *dir = libssh2_sftp_opendir(sftp, path.c_str());
    if (dir == nullptr) {
        std::string message = LastError(session, "sftp opendir failed");
        libssh2_sftp_shutdown(sftp);
        return std::string("{\"error\":\"") + JsonEscape(message) + "\"}";
    }
    std::string items;
    char name[512];
    char longEntry[1024];
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int count = 0;
    for (;;) {
        int got = libssh2_sftp_readdir_ex(dir, name, sizeof(name), longEntry, sizeof(longEntry), &attrs);
        if (got <= 0) {
            break;
        }
        if (!items.empty()) {
            items += ",";
        }
        const char *kind = LIBSSH2_SFTP_S_ISDIR(attrs.permissions) ? "dir" : "file";
        items += std::string("{\"name\":\"") + JsonEscape(std::string(name))
            + "\",\"kind\":\"" + kind + "\",\"size\":" + std::to_string(attrs.filesize) + "}";
        count++;
        if (count >= 500) {
            break;
        }
    }
    libssh2_sftp_closedir(dir);
    libssh2_sftp_shutdown(sftp);
    return std::string("{\"entries\":[") + items + "],\"count\":" + std::to_string(count) + "}";
}


// --- 本地转发（-L）---------------------------------------------------------------------------
// 设备监听 127.0.0.1:<port>，每个接入连接经 remote_host:remote_port 出去。
//
// libssh2 的 session 不是线程安全的，而一条转发连接会长时间占着两个 fd。所以每个转发只用
// 一个工作线程、一次处理一个接入连接，用 poll 在本地 fd 与 channel 之间倒数据；不并发是为了
// 不引入「多线程同时碰同一个 session」这个崩溃面。并发连接排在本地 backlog 里，处理完一条
// 再来下一条。
//
// channel 走非阻塞模式：阻塞模式下 libssh2_channel_read 会在没有数据时停住，poll 就没意义了。

struct Forward {
    int handle = 0;
    int listenSock = -1;
    std::string remoteHost;
    int remotePort = 0;
    int localPort = 0;
    std::atomic<bool> stop{false};
    std::thread worker;
};

std::map<int, std::shared_ptr<Forward>> g_forwards;
int g_nextForward = 1;

/** Wait until the session can make progress, in the direction libssh2 reported.
 *
 *  An EAGAIN from a channel is about the ssh transport, not about the local fd: waiting on the
 *  local socket for POLLOUT would spin until the timeout while the transport stays blocked.
 */
void WaitForSession(LIBSSH2_SESSION *session, int sessionSock, int timeoutMs)
{
    int direction = libssh2_session_block_directions(session);
    short events = 0;
    if ((direction & LIBSSH2_SESSION_BLOCK_INBOUND) != 0) {
        events |= POLLIN;
    }
    if ((direction & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0) {
        events |= POLLOUT;
    }
    if (events == 0) {
        events = POLLIN | POLLOUT;
    }
    struct pollfd wait;
    wait.fd = sessionSock;
    wait.events = events;
    wait.revents = 0;
    poll(&wait, 1, timeoutMs);
}

/** 在一条已建立的 session 上，把本地 fd 与远端 channel 对接，直到任一端关闭。 */
void PumpConnection(LIBSSH2_SESSION *session, int sessionSock, int localFd,
    const std::string &remoteHost, int remotePort)
{
    LIBSSH2_CHANNEL *channel = libssh2_channel_direct_tcpip(session, remoteHost.c_str(), remotePort);
    if (channel == nullptr) {
        close(localFd);
        return;
    }
    libssh2_channel_set_blocking(channel, 0);
    char buffer[4096];
    bool alive = true;
    while (alive) {
        struct pollfd fds[2];
        fds[0].fd = localFd;
        fds[0].events = POLLIN;
        fds[0].revents = 0;
        // The second entry is the ssh transport: inbound data has to wake this loop, and the
        // previous version filled both entries with localFd while polling only one of them.
        fds[1].fd = sessionSock;
        fds[1].events = POLLIN;
        fds[1].revents = 0;
        int ready = poll(fds, 2, 200);
        if (ready > 0 && (fds[0].revents & POLLIN) != 0) {
            ssize_t got = read(localFd, buffer, sizeof(buffer));
            if (got <= 0) {
                break;
            }
            size_t sent = 0;
            while (sent < static_cast<size_t>(got)) {
                ssize_t put = libssh2_channel_write(channel, buffer + sent,
                    static_cast<size_t>(got) - sent);
                if (put > 0) {
                    sent += static_cast<size_t>(put);
                    continue;
                }
                if (put == LIBSSH2_ERROR_EAGAIN) {
                    WaitForSession(session, sessionSock, 50);
                    continue;
                }
                alive = false;
                break;
            }
            if (!alive) {
                break;
            }
        }
        // 远端 -> 本地
        for (;;) {
            ssize_t got = libssh2_channel_read(channel, buffer, sizeof(buffer));
            if (got > 0) {
                size_t sent = 0;
                while (sent < static_cast<size_t>(got)) {
                    ssize_t put = write(localFd, buffer + sent, static_cast<size_t>(got) - sent);
                    if (put <= 0) {
                        break;
                    }
                    sent += static_cast<size_t>(put);
                }
                continue;
            }
            if (got == LIBSSH2_ERROR_EAGAIN) {
                break;
            }
            alive = false;
            break;
        }
    }
    libssh2_channel_close(channel);
    libssh2_channel_free(channel);
    close(localFd);
}

/** 起一条转发：返回转发 id，失败返回错误。 */
std::string ForwardStart(int sessionHandle, int localPort, const std::string &remoteHost, int remotePort)
{
    std::shared_ptr<Connection> conn;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_connections.find(sessionHandle);
        if (it == g_connections.end()) {
            return std::string("{\"error\":\"no such handle\"}");
        }
        conn = it->second;
    }
    std::lock_guard<std::mutex> ioLock(conn->io);
    int listenSock = socket(AF_INET, SOCK_STREAM, 0);
    if (listenSock < 0) {
        return std::string("{\"error\":\"listen socket failed\"}");
    }
    int reuse = 1;
    setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<uint16_t>(localPort));
    if (bind(listenSock, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0) {
        close(listenSock);
        return std::string("{\"error\":\"bind failed\"}");
    }
    if (listen(listenSock, 8) != 0) {
        close(listenSock);
        return std::string("{\"error\":\"listen failed\"}");
    }
    socklen_t len = sizeof(addr);
    getsockname(listenSock, reinterpret_cast<struct sockaddr *>(&addr), &len);
    const int boundPort = ntohs(addr.sin_port);

    auto forward = std::make_shared<Forward>();
    forward->handle = g_nextForward++;
    forward->listenSock = listenSock;
    forward->remoteHost = remoteHost;
    forward->remotePort = remotePort;
    forward->localPort = boundPort;
    LIBSSH2_SESSION *session = conn->session;
    const int sessionSock = conn->sock;
    Forward *raw = forward.get();
    forward->worker = std::thread([raw, session, sessionSock]() {
        while (!raw->stop.load()) {
            struct pollfd wait[1];
            wait[0].fd = raw->listenSock;
            wait[0].events = POLLIN;
            wait[0].revents = 0;
            int ready = poll(wait, 1, 300);
            if (ready <= 0) {
                continue;
            }
            int client = accept(raw->listenSock, nullptr, nullptr);
            if (client < 0) {
                continue;
            }
            PumpConnection(session, sessionSock, client, raw->remoteHost, raw->remotePort);
        }
    });
    const int id = forward->handle;
    g_forwards[id] = forward;
    return std::string("{\"forward\":") + std::to_string(id) + ",\"local_port\":"
        + std::to_string(boundPort) + "}";
}

std::string ForwardStop(int forwardId)
{
    std::shared_ptr<Forward> forward;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        auto it = g_forwards.find(forwardId);
        if (it == g_forwards.end()) {
            return std::string("{\"error\":\"no such forward\"}");
        }
        forward = it->second;
        g_forwards.erase(it);
    }
    forward->stop.store(true);
    if (forward->worker.joinable()) {
        forward->worker.join();
    }
    close(forward->listenSock);
    return std::string("{\"stopped\":") + std::to_string(forwardId) + "}";
}

// 一次调用：op 加七个字符串参数。
//
// 数字也走字符串，入口因此只有一种解析（ArgString），不必为每个 op 写一遍 napi_typeof
// 分支。工作线程只读这份拷贝，入口线程不碰任何网络调用。
struct SshJob {
    std::string op;
    std::string args[7];
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

/** 把字符串参数当整数读；空串给 0。 */
int AsInt(const std::string &text)
{
    if (text.empty()) {
        return 0;
    }
    return atoi(text.c_str());
}

std::string RunOp(const SshJob &job)
{
    const std::string &a = job.args[0];
    const std::string &b = job.args[1];
    const std::string &c = job.args[2];
    const std::string &d = job.args[3];
    if (job.op == "version") {
        return std::string("{\"libssh2\":\"") + libssh2_version(0) + "\"}";
    }
    if (job.op == "open") {
        // a=host b=port c=user d=password e=key f=pubkey g=confirm_only
        const std::string &e = job.args[4];
        const std::string &f = job.args[5];
        const bool confirmOnly = job.args[6] == "1";
        return SshOpen(a, AsInt(b), c, d, e, f, confirmOnly);
    }
    if (job.op == "exec") {
        return SshExec(AsInt(a), b);
    }
    if (job.op == "close") {
        return SshClose(AsInt(a));
    }
    if (job.op == "sftp_read") {
        return SftpRead(AsInt(a), b);
    }
    if (job.op == "sftp_write") {
        return SftpWrite(AsInt(a), b, c);
    }
    if (job.op == "sftp_list") {
        return SftpList(AsInt(a), b.empty() ? std::string(".") : b);
    }
    if (job.op == "forward") {
        // a=handle b=local_port c=remote_host d=remote_port
        if (c.empty() || AsInt(d) <= 0) {
            return std::string("{\"error\":\"forward needs remote host and port\"}");
        }
        return ForwardStart(AsInt(a), AsInt(b), c, AsInt(d));
    }
    if (job.op == "forward_stop") {
        return ForwardStop(AsInt(a));
    }
    return std::string("{\"error\":\"unknown op\"}");
}

void SshExecute(napi_env env, void *data)
{
    SshJob *job = static_cast<SshJob *>(data);
    job->result = RunOp(*job);
}

void SshComplete(napi_env env, napi_status status, void *data)
{
    SshJob *job = static_cast<SshJob *>(data);
    napi_value result = nullptr;
    napi_create_string_utf8(env, job->result.c_str(), job->result.size(), &result);
    if (status == napi_ok) {
        napi_resolve_deferred(env, job->deferred, result);
    } else {
        napi_reject_deferred(env, job->deferred, result);
    }
    napi_delete_async_work(env, job->work);
    delete job;
}

napi_value SshCallEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value args[8] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MakeString(env, "{\"error\":\"op is required\"}");
    }
    SshJob *job = new SshJob();
    job->op = ArgString(env, args[0]);
    for (size_t i = 1; i < 8 && i < argc; i++) {
        job->args[i - 1] = ArgString(env, args[i]);
    }
    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "navi_ssh:call", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, SshExecute, SshComplete, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    libssh2_init(0);
    napi_property_descriptor desc[] = {
        {"sshCall", nullptr, SshCallEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 1, desc);
    OH_LOG_INFO(LOG_APP, "navi_ssh exports=1 libssh2=%{public}s", libssh2_version(0));
    return exports;
}

}  // namespace

// 独立模块：能力各自一个 so，ArkTS 侧 import 'libnavi_ssh.so' 直接拿到 sshCall。
// 模块名与文件名一致，缺文件时那一句 import 就失败，调用方据此决定不注册工具。
static napi_module sshModule = {
    1, 0, nullptr, Init, "navi_ssh", nullptr, { 0 },
};

extern "C" __attribute__((constructor)) void RegisterNaviSsh(void)
{
    napi_module_register(&sshModule);
}

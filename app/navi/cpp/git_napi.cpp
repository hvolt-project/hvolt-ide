// 项目仓库的只读 git 操作，经 libgit2 在应用进程内执行。
//
// 设备沙箱禁止 execve，所以调不了 git 可执行文件；libgit2 是库，可以直接链进来。
// 这里只暴露契约里的只读四个 op（status/diff/log/show），写类 op 与快照库另行实现。
//
// 每次调用都自己打开、自己释放仓库对象：工具调用之间不保留任何状态，这样一次失败的调用
// 不会让下一次拿到半开的仓库。

#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <git2.h>
#include "napi/native_api.h"
#include <hilog/log.h>

namespace {

// JSON 字符串转义：路径与提交信息都可能带引号、反斜杠与控制字符。
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

// 从 napi 值取字符串；缺省返回空串。
std::string ErrorJson(const char *fallback)
{
    const git_error *err = git_error_last();
    return std::string("{\"error\":\"") + JsonEscape(err == nullptr ? fallback : err->message) + "\"}";
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

std::string ArgStringOr(napi_env env, napi_value value, const char *fallback)
{
    std::string s = ArgString(env, value);
    return s.empty() ? std::string(fallback) : s;
}

napi_value MakeString(napi_env env, const std::string &text)
{
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

// 打开仓库：只在这个目录里找，不向父目录逐级搜索，避免误抓到工作区上级的仓库。
// libgit2 1.8 的 open_ext 直接收 flags，没有 options 结构。
int OpenRepository(const std::string &dir, git_repository **out)
{
    return git_repository_open_ext(out, dir.c_str(), GIT_REPOSITORY_OPEN_NO_SEARCH, nullptr);
}

// 四个 op 都可能遍历工作树（status 与 diff 最重），在主线程做会触发三秒冻结。
// 统一走 napi_async_work：参数在入口线程拷成 C++ 字符串，结果在工作线程算。
enum class GitOp { STATUS, LOG, DIFF, SHOW, ADD, COMMIT, BRANCH, CHECKOUT, FETCH, PUSH, CLONE };

struct GitJob {
    GitOp op = GitOp::STATUS;
    std::string repoDir;
    std::string second;
    bool flag = false;
    int limit = 20;
    /** add 用：要加入索引的路径；空表示全部。 */
    std::vector<std::string> paths;
    /** fetch/push/clone 用：HTTPS 凭据，空表示匿名。 */
    std::string credUser;
    std::string credPass;
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

// 四个算子在后面定义；这里先声明，工作线程执行体只用到类型。
std::string GitStatus(const std::string &repoDir);
std::string GitLog(const std::string &repoDir, int limit);
std::string GitDiff(const std::string &repoDir, const std::string &path, bool staged);
std::string GitShow(const std::string &repoDir, const std::string &sha);
std::string GitAdd(const std::string &repoDir, const std::vector<std::string> &paths);
std::string GitCommit(const std::string &repoDir, const std::string &message);
std::string GitBranch(const std::string &repoDir, const std::string &name, bool force);
std::string GitCheckout(const std::string &repoDir, const std::string &ref);
std::string GitFetch(const std::string &repoDir, const std::string &user, const std::string &password);
std::string GitPush(const std::string &repoDir, const std::string &refspec,
    const std::string &user, const std::string &password);
std::string GitClone(const std::string &url, const std::string &dest,
    const std::string &user, const std::string &password);

void GitExecute(napi_env env, void *data)
{
    GitJob *job = static_cast<GitJob *>(data);
    switch (job->op) {
        case GitOp::STATUS:
            job->result = GitStatus(job->repoDir);
            break;
        case GitOp::LOG:
            job->result = GitLog(job->repoDir, job->limit);
            break;
        case GitOp::DIFF:
            job->result = GitDiff(job->repoDir, job->second, job->flag);
            break;
        case GitOp::SHOW:
            job->result = GitShow(job->repoDir, job->second);
            break;
        case GitOp::ADD:
            job->result = GitAdd(job->repoDir, job->paths);
            break;
        case GitOp::COMMIT:
            job->result = GitCommit(job->repoDir, job->second);
            break;
        case GitOp::BRANCH:
            job->result = GitBranch(job->repoDir, job->second, job->flag);
            break;
        case GitOp::CHECKOUT:
            job->result = GitCheckout(job->repoDir, job->second);
            break;
        case GitOp::FETCH:
            job->result = GitFetch(job->repoDir, job->credUser, job->credPass);
            break;
        case GitOp::PUSH:
            job->result = GitPush(job->repoDir, job->second, job->credUser, job->credPass);
            break;
        case GitOp::CLONE:
            job->result = GitClone(job->second, job->repoDir, job->credUser, job->credPass);
            break;
    }
}

void GitComplete(napi_env env, napi_status status, void *data)
{
    GitJob *job = static_cast<GitJob *>(data);
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

/** 把一个已填好参数的 job 变成 Promise 交给工作线程。 */
napi_value QueueGitJob(napi_env env, GitJob *job, const char *name)
{
    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value workName = nullptr;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &workName);
    napi_create_async_work(env, nullptr, workName, GitExecute, GitComplete, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

std::string GitStatus(const std::string &repoDir)
{
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        const git_error *err = git_error_last();
        return std::string("{\"error\":\"") + JsonEscape(err == nullptr ? "open failed" : err->message) + "\"}";
    }
    git_status_options opts = GIT_STATUS_OPTIONS_INIT;
    opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS
        | GIT_STATUS_OPT_INCLUDE_IGNORED;
    git_status_list *list = nullptr;
    if (git_status_list_new(&list, repo, &opts) != 0) {
        const git_error *err = git_error_last();
        git_repository_free(repo);
        return std::string("{\"error\":\"") + JsonEscape(err == nullptr ? "status failed" : err->message) + "\"}";
    }

    std::string items;
    size_t count = git_status_list_entrycount(list);
    for (size_t i = 0; i < count; i++) {
        const git_status_entry *entry = git_status_byindex(list, i);
        if (entry == nullptr) {
            continue;
        }
        const char *path = entry->index_to_workdir != nullptr && entry->index_to_workdir->new_file.path != nullptr
            ? entry->index_to_workdir->new_file.path
            : (entry->head_to_index != nullptr && entry->head_to_index->old_file.path != nullptr
                ? entry->head_to_index->old_file.path : "");
        unsigned int st = entry->status;
        const char *flag = "modified";
        if ((st & GIT_STATUS_WT_NEW) != 0) {
            flag = "untracked";
        } else if ((st & GIT_STATUS_INDEX_NEW) != 0) {
            flag = "added";
        } else if ((st & GIT_STATUS_WT_DELETED) != 0 || (st & GIT_STATUS_INDEX_DELETED) != 0) {
            flag = "deleted";
        } else if ((st & GIT_STATUS_IGNORED) != 0) {
            flag = "ignored";
        } else if ((st & GIT_STATUS_CONFLICTED) != 0) {
            flag = "conflicted";
        }
        if (!items.empty()) {
            items += ",";
        }
        items += std::string("{\"path\":\"") + JsonEscape(path) + "\",\"status\":\"" + flag + "\"}";
    }
    git_status_list_free(list);
    git_repository_free(repo);
    return std::string("{\"entries\":[") + items + "],\"count\":" + std::to_string(count) + "}";
}

std::string GitLog(const std::string &repoDir, int limit)
{
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        const git_error *err = git_error_last();
        return std::string("{\"error\":\"") + JsonEscape(err == nullptr ? "open failed" : err->message) + "\"}";
    }
    git_revwalk *walk = nullptr;
    if (git_revwalk_new(&walk, repo) != 0) {
        git_repository_free(repo);
        return std::string("{\"error\":\"revwalk failed\"}");
    }
    git_revwalk_sorting(walk, GIT_SORT_TIME);
    std::string items;
    int emitted = 0;
    if (git_revwalk_push_head(walk) == 0) {
        git_oid oid;
        while (emitted < limit && git_revwalk_next(&oid, walk) == 0) {
            git_commit *commit = nullptr;
            if (git_commit_lookup(&commit, repo, &oid) != 0) {
                continue;
            }
            char sha[GIT_OID_HEXSZ + 1] = {0};
            git_oid_tostr(sha, sizeof(sha), &oid);
            const char *summary = git_commit_summary(commit);
            const char *author = git_commit_author(commit) == nullptr ? "" : git_commit_author(commit)->name;
            if (!items.empty()) {
                items += ",";
            }
            items += std::string("{\"sha\":\"") + sha + "\",\"summary\":\""
                + JsonEscape(summary == nullptr ? "" : summary) + "\",\"author\":\""
                + JsonEscape(author == nullptr ? "" : author) + "\",\"time\":"
                + std::to_string(static_cast<long long>(git_commit_time(commit))) + "}";
            git_commit_free(commit);
            emitted++;
        }
    }
    git_revwalk_free(walk);
    git_repository_free(repo);
    return std::string("{\"commits\":[") + items + "],\"count\":" + std::to_string(emitted) + "}";
}


// --- 读类：diff 与 show ---------------------------------------------------------------------
// 两者只读仓库、不改状态。调用点在 GitExecute 里（DIFF/SHOW 两个 op），原先只有声明没有实现，
// 链接不过：ld.lld 报 undefined symbol (anonymous namespace)::GitDiff。

std::string GitDiff(const std::string &repoDir, const std::string &path, bool staged)
{
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        return ErrorJson("open failed");
    }
    git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
    char *spec = const_cast<char *>(path.c_str());
    if (!path.empty()) {
        opts.pathspec.count = 1;
        opts.pathspec.strings = &spec;
    }
    git_diff *diff = nullptr;
    int rc = 0;
    if (staged) {
        git_reference *ref = nullptr;
        git_commit *commit = nullptr;
        git_tree *head = nullptr;
        git_index *index = nullptr;
        if (git_repository_head(&ref, repo) == 0) {
            if (git_reference_peel(reinterpret_cast<git_object **>(&commit), ref, GIT_OBJECT_COMMIT) == 0) {
                git_commit_tree(&head, commit);
            }
        }
        git_repository_index(&index, repo);
        rc = git_diff_tree_to_index(&diff, repo, head, index, &opts);
        if (index != nullptr) {
            git_index_free(index);
        }
        if (head != nullptr) {
            git_tree_free(head);
        }
        if (commit != nullptr) {
            git_commit_free(commit);
        }
        if (ref != nullptr) {
            git_reference_free(ref);
        }
    } else {
        rc = git_diff_index_to_workdir(&diff, repo, nullptr, &opts);
    }
    if (rc != 0) {
        const git_error *err = git_error_last();
        git_repository_free(repo);
        return ErrorJson(err == nullptr ? "diff failed" : err->message);
    }
    git_buf buf = GIT_BUF_INIT_CONST(NULL, 0);
    std::string out = "{\"diff\":\"";
    if (git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH) == 0 && buf.ptr != nullptr) {
        out += JsonEscape(buf.ptr);
    }
    out += "\"}";
    git_buf_dispose(&buf);
    git_diff_free(diff);
    git_repository_free(repo);
    return out;
}

std::string GitShow(const std::string &repoDir, const std::string &sha)
{
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        return ErrorJson("open failed");
    }
    git_object *obj = nullptr;
    if (git_revparse_single(&obj, repo, sha.c_str()) != 0) {
        const git_error *err = git_error_last();
        git_repository_free(repo);
        return ErrorJson(err == nullptr ? "unknown revision" : err->message);
    }
    git_commit *commit = nullptr;
    if (git_object_peel(reinterpret_cast<git_object **>(&commit), obj, GIT_OBJECT_COMMIT) != 0) {
        git_object_free(obj);
        git_repository_free(repo);
        return ErrorJson("not a commit");
    }
    const char *message = git_commit_message(commit);
    const git_signature *author = git_commit_author(commit);
    std::string out = "{\"sha\":\"" + JsonEscape(sha.c_str()) + "\",\"message\":\"" +
        JsonEscape(message == nullptr ? "" : message) + "\",\"author\":\"" +
        JsonEscape(author == nullptr || author->name == nullptr ? "" : author->name) + "\",\"patch\":\"";
    // 有父提交就两者相减，首提交与空树比较。
    git_tree *tree = nullptr;
    git_tree *parentTree = nullptr;
    git_commit_tree(&tree, commit);
    if (git_commit_parentcount(commit) > 0) {
        git_commit *parent = nullptr;
        if (git_commit_parent(&parent, commit, 0) == 0) {
            git_commit_tree(&parentTree, parent);
            git_commit_free(parent);
        }
    }
    git_diff *diff = nullptr;
    git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
    if (git_diff_tree_to_tree(&diff, repo, parentTree, tree, &opts) == 0) {
        git_buf buf = GIT_BUF_INIT_CONST(NULL, 0);
        if (git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH) == 0 && buf.ptr != nullptr) {
            out += JsonEscape(buf.ptr);
        }
        git_buf_dispose(&buf);
        git_diff_free(diff);
    }
    out += "\"}";
    if (tree != nullptr) {
        git_tree_free(tree);
    }
    if (parentTree != nullptr) {
        git_tree_free(parentTree);
    }
    git_commit_free(commit);
    git_object_free(obj);
    git_repository_free(repo);
    return out;
}

// --- 写类 op -------------------------------------------------------------------------------
// 四个写操作都改仓库状态，approval 在 ArkTS 侧是 confirm；这里只保证失败时回结构化错误，
// 不留半截状态：索引先写暂存，提交失败时不移动 HEAD。

std::string GitAdd(const std::string &repoDir, const std::vector<std::string> &paths)
{
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        return ErrorJson("open failed");
    }
    git_index *index = nullptr;
    if (git_repository_index(&index, repo) != 0) {
        git_repository_free(repo);
        return ErrorJson("index failed");
    }
    std::vector<char *> raw;
    raw.reserve(paths.size());
    for (const std::string &path : paths) {
        raw.push_back(const_cast<char *>(path.c_str()));
    }
    git_strarray spec = {raw.empty() ? nullptr : raw.data(), raw.size()};
    int rc = git_index_add_all(index, &spec, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr);
    if (rc == 0) {
        rc = git_index_write(index);
    }
    size_t staged = git_index_entrycount(index);
    git_index_free(index);
    git_repository_free(repo);
    if (rc != 0) {
        return ErrorJson("add failed");
    }
    return std::string("{\"staged\":") + std::to_string(staged) + "}";
}

std::string GitCommit(const std::string &repoDir, const std::string &message)
{
    if (message.empty()) {
        return "{\"error\":\"commit message is empty\"}";
    }
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        return ErrorJson("open failed");
    }
    git_index *index = nullptr;
    if (git_repository_index(&index, repo) != 0) {
        git_repository_free(repo);
        return ErrorJson("index failed");
    }
    git_oid treeOid;
    int rc = git_index_write_tree(&treeOid, index);
    git_tree *tree = nullptr;
    if (rc == 0) {
        rc = git_tree_lookup(&tree, repo, &treeOid);
    }
    git_signature *sig = nullptr;
    git_signature_now(&sig, "hvolt", "hvolt@local");
    git_commit *parent = nullptr;
    git_commit *parents[1] = {nullptr};
    int parentCount = 0;
    git_reference *head = nullptr;
    if (git_repository_head(&head, repo) == 0) {
        git_reference_peel(reinterpret_cast<git_object **>(&parent), head, GIT_OBJECT_COMMIT);
        if (parent != nullptr) {
            parents[0] = parent;
            parentCount = 1;
        }
    }
    git_oid commitOid;
    if (rc == 0) {
        rc = git_commit_create(&commitOid, repo, "HEAD", sig, sig, nullptr, message.c_str(),
            tree, parentCount, parents);
    }
    char sha[GIT_OID_HEXSZ + 1] = {0};
    if (rc == 0) {
        git_oid_tostr(sha, sizeof(sha), &commitOid);
    }
    if (parent != nullptr) {
        git_commit_free(parent);
    }
    if (head != nullptr) {
        git_reference_free(head);
    }
    if (sig != nullptr) {
        git_signature_free(sig);
    }
    if (tree != nullptr) {
        git_tree_free(tree);
    }
    git_index_free(index);
    git_repository_free(repo);
    if (rc != 0) {
        return ErrorJson("commit failed");
    }
    return std::string("{\"sha\":\"") + sha + "\"}";
}

std::string GitBranch(const std::string &repoDir, const std::string &name, bool force)
{
    if (name.empty()) {
        return "{\"error\":\"branch name is empty\"}";
    }
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        return ErrorJson("open failed");
    }
    git_object *target = nullptr;
    if (git_revparse_single(&target, repo, "HEAD") != 0) {
        git_repository_free(repo);
        return ErrorJson("no HEAD to branch from");
    }
    git_commit *commit = nullptr;
    int rc = git_object_peel(reinterpret_cast<git_object **>(&commit), target, GIT_OBJECT_COMMIT);
    git_reference *created = nullptr;
    if (rc == 0) {
        rc = git_branch_create(&created, repo, name.c_str(), commit, force ? 1 : 0);
    }
    if (created != nullptr) {
        git_reference_free(created);
    }
    if (commit != nullptr) {
        git_commit_free(commit);
    }
    git_object_free(target);
    git_repository_free(repo);
    if (rc != 0) {
        return ErrorJson("branch create failed");
    }
    return std::string("{\"branch\":\"") + JsonEscape(name) + "\"}";
}

namespace {

struct CredPayload {
    std::string user;
    std::string password;
};

int CredentialsCb(git_credential **out, const char *url, const char *usernameFromUrl,
    unsigned int allowed, void *payload)
{
    (void)url;
    (void)usernameFromUrl;
    const CredPayload *p = static_cast<const CredPayload *>(payload);
    if (p != nullptr && !p->user.empty()
        && (allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT) != 0) {
        return git_credential_userpass_plaintext_new(out, p->user.c_str(), p->password.c_str());
    }
    if ((allowed & GIT_CREDENTIAL_DEFAULT) != 0) {
        return git_credential_default_new(out);
    }
    return GIT_EUSER;
}

std::string RemoteError(const char *fallback)
{
    const git_error *err = git_error_last();
    return std::string("{\"error\":\"") + JsonEscape(err == nullptr ? fallback : err->message)
        + "\"}";
}

}  // namespace

/** Fetch every ref of `origin`. */
std::string GitFetch(const std::string &repoDir, const std::string &user,
    const std::string &password)
{
    git_repository *repo = nullptr;
    if (git_repository_open(&repo, repoDir.c_str()) != 0) {
        return RemoteError("open failed");
    }
    git_remote *remote = nullptr;
    if (git_remote_lookup(&remote, repo, "origin") != 0) {
        git_repository_free(repo);
        return RemoteError("no origin remote");
    }
    CredPayload cred{user, password};
    git_fetch_options opts = GIT_FETCH_OPTIONS_INIT;
    opts.callbacks.credentials = CredentialsCb;
    opts.callbacks.payload = &cred;
    const int rc = git_remote_fetch(remote, nullptr, &opts, nullptr);
    git_remote_free(remote);
    git_repository_free(repo);
    if (rc != 0) {
        return RemoteError("fetch failed");
    }
    return "{\"ok\":true}";
}

/** Push one refspec (default: the current branch to origin under the same name). */
std::string GitPush(const std::string &repoDir, const std::string &refspec,
    const std::string &user, const std::string &password)
{
    git_repository *repo = nullptr;
    if (git_repository_open(&repo, repoDir.c_str()) != 0) {
        return RemoteError("open failed");
    }
    git_remote *remote = nullptr;
    if (git_remote_lookup(&remote, repo, "origin") != 0) {
        git_repository_free(repo);
        return RemoteError("no origin remote");
    }
    std::string spec = refspec;
    if (spec.empty()) {
        git_reference *head = nullptr;
        if (git_repository_head(&head, repo) != 0) {
            git_remote_free(remote);
            git_repository_free(repo);
            return RemoteError("no current branch");
        }
        const char *name = git_reference_name(head);
        spec = std::string(name) + ":" + name;
        git_reference_free(head);
    }
    char *specItems[1] = {const_cast<char *>(spec.c_str())};
    git_strarray specs{specItems, 1};
    CredPayload cred{user, password};
    git_push_options opts = GIT_PUSH_OPTIONS_INIT;
    opts.callbacks.credentials = CredentialsCb;
    opts.callbacks.payload = &cred;
    const int rc = git_remote_push(remote, &specs, &opts);
    git_remote_free(remote);
    git_repository_free(repo);
    if (rc != 0) {
        return RemoteError("push failed");
    }
    return "{\"ok\":true,\"refspec\":\"" + JsonEscape(spec) + "\"}";
}

/** Clone `url` into `dest`. */
std::string GitClone(const std::string &url, const std::string &dest,
    const std::string &user, const std::string &password)
{
    if (url.empty() || dest.empty()) {
        return std::string("{\"error\":\"clone needs a url and a destination\"}");
    }
    CredPayload cred{user, password};
    git_clone_options opts = GIT_CLONE_OPTIONS_INIT;
    opts.fetch_opts.callbacks.credentials = CredentialsCb;
    opts.fetch_opts.callbacks.payload = &cred;
    git_repository *repo = nullptr;
    if (git_clone(&repo, url.c_str(), dest.c_str(), &opts) != 0) {
        return RemoteError("clone failed");
    }
    git_repository_free(repo);
    return "{\"ok\":true,\"path\":\"" + JsonEscape(dest) + "\"}";
}

std::string GitCheckout(const std::string &repoDir, const std::string &ref)
{
    if (ref.empty()) {
        return "{\"error\":\"ref is empty\"}";
    }
    git_repository *repo = nullptr;
    if (OpenRepository(repoDir, &repo) != 0) {
        return ErrorJson("open failed");
    }
    git_object *target = nullptr;
    if (git_revparse_single(&target, repo, ref.c_str()) != 0) {
        git_repository_free(repo);
        return ErrorJson("bad ref");
    }
    git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
    opts.checkout_strategy = GIT_CHECKOUT_SAFE;
    int rc = git_checkout_tree(repo, target, &opts);
    if (rc == 0) {
        rc = git_repository_set_head(repo, (std::string("refs/heads/") + ref).c_str());
        if (rc != 0) {
            // ref 不是分支名时退回按原样设 head。
            rc = git_repository_set_head(repo, ref.c_str());
        }
    }
    std::string resolved;
    const char *headName = nullptr;
    git_reference *head = nullptr;
    if (git_repository_head(&head, repo) == 0) {
        headName = git_reference_name(head);
        if (headName != nullptr) {
            resolved = headName;
        }
        git_reference_free(head);
    }
    git_object_free(target);
    git_repository_free(repo);
    if (rc != 0) {
        return ErrorJson("checkout failed");
    }
    return std::string("{\"head\":\"") + JsonEscape(resolved) + "\"}";
}

// 一个入口，八个算子。
//
// 之前是八个 `Git*Entry`，每个都在重复「读 argc → new GitJob → 设字段 → 排队」，差别只有
// 枚举值和参数名——八份同构代码，改一处要么改八遍，要么漏掉几处。参数收成四个字符串由
// `op` 决定含义，对齐 ArkTS 侧那一个 `git(op, args)` 工具。
napi_value GitVersion(napi_env env, napi_callback_info info)
{
    int major = 0;
    int minor = 0;
    int rev = 0;
    git_libgit2_version(&major, &minor, &rev);
    char buf[64] = {0};
    snprintf(buf, sizeof(buf), "%d.%d.%d", major, minor, rev);
    return MakeString(env, std::string("{\"libgit2\":\"") + buf + "\"}");
}

napi_value GitCallEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MakeString(env, "{\"error\":\"op and repoDir are required\"}");
    }
    const std::string op = ArgString(env, args[0]);
    const std::string repoDir = ArgString(env, args[1]);
    const std::string first = argc >= 3 ? ArgString(env, args[2]) : std::string();
    const std::string second = argc >= 4 ? ArgString(env, args[3]) : std::string();
    GitJob *job = new GitJob();
    job->repoDir = repoDir;
    {
        // `second` carries "user:password" for the network ops; a colon in the password is kept.
        const size_t colon = second.find(':');
        if (colon != std::string::npos) {
            job->credUser = second.substr(0, colon);
            job->credPass = second.substr(colon + 1);
        }
    }
    const char *name = nullptr;
    if (op == "status") {
        job->op = GitOp::STATUS;
        name = "navi:gitStatus";
    } else if (op == "log") {
        job->op = GitOp::LOG;
        job->limit = 20;
        if (!first.empty()) {
            int value = atoi(first.c_str());
            if (value > 0) {
                job->limit = value > 200 ? 200 : value;
            }
        }
        name = "navi:gitLog";
    } else if (op == "diff") {
        job->op = GitOp::DIFF;
        job->second = first;
        job->flag = second == "staged";
        name = "navi:gitDiff";
    } else if (op == "show") {
        job->op = GitOp::SHOW;
        job->second = first;
        name = "navi:gitShow";
    } else if (op == "add") {
        job->op = GitOp::ADD;
        // 路径用换行分隔：一个路径本身不含换行，比引入 JSON 解析轻。
        size_t at = 0;
        while (at <= first.size() && !first.empty()) {
            size_t next = first.find('\n', at);
            if (next == std::string::npos) {
                job->paths.push_back(first.substr(at));
                break;
            }
            job->paths.push_back(first.substr(at, next - at));
            at = next + 1;
        }
        name = "navi:gitAdd";
    } else if (op == "commit") {
        job->op = GitOp::COMMIT;
        job->second = first;
        name = "navi:gitCommit";
    } else if (op == "branch") {
        job->op = GitOp::BRANCH;
        job->second = first;
        job->flag = second == "force";
        name = "navi:gitBranch";
    } else if (op == "checkout") {
        job->op = GitOp::CHECKOUT;
        job->second = first;
        name = "navi:gitCheckout";
    } else if (op == "fetch") {
        job->op = GitOp::FETCH;
        name = "navi:gitFetch";
    } else if (op == "push") {
        job->op = GitOp::PUSH;
        job->second = first;
        name = "navi:gitPush";
    } else if (op == "clone") {
        job->op = GitOp::CLONE;
        // args: repoDir is the url, `first` the destination directory.
        job->second = job->repoDir;
        job->repoDir = first;
        name = "navi:gitClone";
    } else {
        delete job;
        return MakeString(env, "{\"error\":\"unknown op\"}");
    }
    return QueueGitJob(env, job, name);
}

std::vector<std::string> ArgStringArray(napi_env env, napi_value value)
{
    std::vector<std::string> out;
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return out;
    }
    uint32_t length = 0;
    if (napi_get_array_length(env, value, &length) != napi_ok) {
        return out;
    }
    for (uint32_t i = 0; i < length; i++) {
        napi_value item = nullptr;
        if (napi_get_element(env, value, i, &item) == napi_ok) {
            std::string text = ArgString(env, item);
            if (!text.empty()) {
                out.push_back(text);
            }
        }
    }
    return out;
}

bool ArgBool(napi_env env, napi_value value)
{
    bool out = false;
    napi_get_value_bool(env, value, &out);
    return out;
}

// ArkTS 侧 (tools/Git.ets) 调的是 gitAdd / gitCommit / gitBranch / gitCheckout 四个独立入口，
// 而这里只有 gitCall 的 op 分发。四个实现留在匿名命名空间内（要用 ArgString 与 QueueGitJob），
// 导出的同名包装放在命名空间外供 RegisterGitNapi 注册。
napi_value GitAddImpl(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    GitJob *job = new GitJob();
    job->repoDir = argc > 0 ? ArgString(env, args[0]) : std::string();
    job->op = GitOp::ADD;
    if (argc > 1) {
        job->paths = ArgStringArray(env, args[1]);
    }
    return QueueGitJob(env, job, "navi:gitAdd");
}

napi_value GitCommitImpl(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    GitJob *job = new GitJob();
    job->repoDir = argc > 0 ? ArgString(env, args[0]) : std::string();
    job->op = GitOp::COMMIT;
    job->second = argc > 1 ? ArgString(env, args[1]) : std::string();
    return QueueGitJob(env, job, "navi:gitCommit");
}

napi_value GitBranchImpl(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    GitJob *job = new GitJob();
    job->repoDir = argc > 0 ? ArgString(env, args[0]) : std::string();
    job->op = GitOp::BRANCH;
    job->second = argc > 1 ? ArgString(env, args[1]) : std::string();
    job->flag = argc > 2 ? ArgBool(env, args[2]) : false;
    return QueueGitJob(env, job, "navi:gitBranch");
}

napi_value GitCheckoutImpl(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    GitJob *job = new GitJob();
    job->repoDir = argc > 0 ? ArgString(env, args[0]) : std::string();
    job->op = GitOp::CHECKOUT;
    job->second = argc > 1 ? ArgString(env, args[1]) : std::string();
    return QueueGitJob(env, job, "navi:gitCheckout");
}

}  // namespace

// 注册函数在匿名命名空间之外：napi_init.cpp 以前置声明调用它，两个实体必须一致。
napi_value GitAddEntry(napi_env env, napi_callback_info info);
napi_value GitCommitEntry(napi_env env, napi_callback_info info);
napi_value GitBranchEntry(napi_env env, napi_callback_info info);
napi_value GitCheckoutEntry(napi_env env, napi_callback_info info);

void RegisterGitNapi(napi_env env, napi_value exports)
{
    git_libgit2_init();
    napi_property_descriptor desc[] = {
        {"gitVersion", nullptr, GitVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gitCall", nullptr, GitCallEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gitAdd", nullptr, GitAddEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gitCommit", nullptr, GitCommitEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gitBranch", nullptr, GitBranchEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gitCheckout", nullptr, GitCheckoutEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 6, desc);
    OH_LOG_INFO(LOG_APP, "navi git exports=6");
}

// 导出的四个入口：实现留在匿名命名空间，这里只做转发。
napi_value GitAddEntry(napi_env env, napi_callback_info info)
{
    return GitAddImpl(env, info);
}

napi_value GitCommitEntry(napi_env env, napi_callback_info info)
{
    return GitCommitImpl(env, info);
}

napi_value GitBranchEntry(napi_env env, napi_callback_info info)
{
    return GitBranchImpl(env, info);
}

napi_value GitCheckoutEntry(napi_env env, napi_callback_info info)
{
    return GitCheckoutImpl(env, info);
}

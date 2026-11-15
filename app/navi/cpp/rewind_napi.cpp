// rewind 的快照库：独立 git 对象库 + 项目根作为工作树。
//
// 三件必须做对的事，每一件做错都会往用户项目里写东西：
// 一是 init 时 workdir_path 必须传 NULL，否则 libgit2 会在工作树里建一个 .git gitlink 文件；
// 二是切工作树用 set_workdir(repo, projectDir, 0)，第三参数 0 才不写 gitlink；
// 三是回退时删未跟踪文件要自己枚举，GIT_RESET_HARD 不删它们。
//
// 快照库与项目自己的 .git 互不相干：这里从不打开项目仓库，只在对齐时读它的 HEAD 与 ref。

#include <string>
#include <vector>
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <cstdio>
#include <sys/stat.h>
#include <git2.h>
#include "napi/native_api.h"
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

std::string ErrorJson(const char *fallback)
{
    const git_error *err = git_error_last();
    return std::string("{\"error\":\"") + JsonEscape(err == nullptr ? fallback : err->message) + "\"}";
}

// 打开或创建快照库，并把工作树指向项目根。update_gitlink = 0：不在项目里写 .git。
int OpenSnapshots(const std::string &snapshotsDir, const std::string &projectDir, git_repository **out)
{
    git_repository *repo = nullptr;
    if (git_repository_open_ext(&repo, snapshotsDir.c_str(), GIT_REPOSITORY_OPEN_NO_SEARCH, nullptr) == 0) {
        git_repository_set_workdir(repo, projectDir.c_str(), 0);
        *out = repo;
        return 0;
    }
    git_repository_init_options opts;
    if (git_repository_init_options_init(&opts, GIT_REPOSITORY_INIT_OPTIONS_VERSION) != 0) {
        return -1;
    }
    opts.flags = GIT_REPOSITORY_INIT_NO_REINIT;
    // 必须 NULL：直接指向项目目录会触发 gitlink 写入。
    opts.workdir_path = nullptr;
    if (git_repository_init_ext(&repo, snapshotsDir.c_str(), &opts) != 0) {
        return -2;
    }
    if (git_repository_set_workdir(repo, projectDir.c_str(), 0) != 0) {
        git_repository_free(repo);
        return -3;
    }
    *out = repo;
    return 0;
}

// 快照不该走进构建产物：一个 build/ 目录常有几百 MB，把它们逐字节哈希一遍会让
// 第一步就卡死（实测进程被系统回收）。排除规则写进快照库自己的 info/exclude，
// 这样只影响快照库，不改项目里的任何 .gitignore。
void WriteExclude(const std::string &snapshotsDir)
{
    std::string dir = snapshotsDir + "/.git/info";
    mkdir((snapshotsDir + "/.git").c_str(), 0777);
    mkdir(dir.c_str(), 0777);
    std::string path = dir + "/exclude";
    FILE *file = fopen(path.c_str(), "w");
    if (file == nullptr) {
        return;
    }
    fputs("build/\n"
          "output/\n"
          "out/\n"
          ".hvolt/\n"
          ".harmony/\n"
          "node_modules/\n"
          "deps/\n"
          "oh_modules/\n"
          "*.hap\n"
          "*.hsp\n"
          "*.app\n", file);
    fclose(file);
}

// 把工作树当前状态写成一个节点。message 由调用方给（步骤号与工具名）。
std::string SnapshotCommit(const std::string &snapshotsDir, const std::string &projectDir,
    const std::string &message)
{
    git_repository *repo = nullptr;
    int rc = OpenSnapshots(snapshotsDir, projectDir, &repo);
    if (rc != 0) {
        return ErrorJson("snapshot open failed");
    }
    WriteExclude(snapshotsDir);
    OH_LOG_INFO(LOG_APP, "rewind: exclude written");
    git_index *index = nullptr;
    if (git_repository_index(&index, repo) != 0) {
        git_repository_free(repo);
        return ErrorJson("index failed");
    }
    OH_LOG_INFO(LOG_APP, "rewind: add_all start");
    git_strarray paths = {nullptr, 0};
    int addRc = git_index_add_all(index, &paths, GIT_INDEX_ADD_DEFAULT | GIT_INDEX_ADD_FORCE,
        nullptr, nullptr);
    OH_LOG_INFO(LOG_APP, "rewind: add_all rc=%{public}d", addRc);
    OH_LOG_INFO(LOG_APP, "rewind: index write start");
    if (git_index_write(index) != 0) {
        git_index_free(index);
        git_repository_free(repo);
        return ErrorJson("index write failed");
    }
    git_oid treeOid;
    if (git_index_write_tree(&treeOid, index) != 0) {
        git_index_free(index);
        git_repository_free(repo);
        return ErrorJson("write tree failed");
    }
    git_tree *tree = nullptr;
    if (git_tree_lookup(&tree, repo, &treeOid) != 0) {
        git_index_free(index);
        git_repository_free(repo);
        return ErrorJson("tree lookup failed");
    }

    git_signature *sig = nullptr;
    git_signature_now(&sig, "rewind", "rewind@local");
    git_oid commitOid;
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
    rc = git_commit_create(&commitOid, repo, "HEAD", sig, sig, nullptr, message.c_str(),
        tree, parentCount, parents);
    char sha[GIT_OID_HEXSZ + 1] = {0};
    git_oid_tostr(sha, sizeof(sha), &commitOid);
    if (parent != nullptr) {
        git_commit_free(parent);
    }
    if (head != nullptr) {
        git_reference_free(head);
    }
    git_signature_free(sig);
    git_tree_free(tree);
    git_index_free(index);
    git_repository_free(repo);
    if (rc != 0) {
        return ErrorJson("commit failed");
    }
    return std::string("{\"sha\":\"") + sha + "\"}";
}

std::string SnapshotList(const std::string &snapshotsDir, const std::string &projectDir, int limit)
{
    git_repository *repo = nullptr;
    if (OpenSnapshots(snapshotsDir, projectDir, &repo) != 0) {
        return ErrorJson("snapshot open failed");
    }
    git_revwalk *walk = nullptr;
    if (git_revwalk_new(&walk, repo) != 0) {
        git_repository_free(repo);
        return ErrorJson("revwalk failed");
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
            if (!items.empty()) {
                items += ",";
            }
            items += std::string("{\"sha\":\"") + sha + "\",\"summary\":\""
                + JsonEscape(summary == nullptr ? "" : summary) + "\",\"time\":"
                + std::to_string(static_cast<long long>(git_commit_time(commit))) + "}";
            git_commit_free(commit);
            emitted++;
        }
    }
    git_revwalk_free(walk);
    git_repository_free(repo);
    return std::string("{\"nodes\":[") + items + "],\"count\":" + std::to_string(emitted) + "}";
}

// 回退到某个节点：先把当前 HEAD 写进 refs/backtrack/，再 hard reset，最后删掉新增的未跟踪文件。
std::string SnapshotRestore(const std::string &snapshotsDir, const std::string &projectDir,
    const std::string &sha)
{
    git_repository *repo = nullptr;
    if (OpenSnapshots(snapshotsDir, projectDir, &repo) != 0) {
        return ErrorJson("snapshot open failed");
    }
    git_object *target = nullptr;
    if (git_revparse_single(&target, repo, sha.c_str()) != 0) {
        git_repository_free(repo);
        return ErrorJson("bad node sha");
    }

    // 回退本身可撤销：把回退前的 HEAD 记到一个 ref 上。
    std::string backtrackName;
    git_oid currentHead;
    git_reference *head = nullptr;
    if (git_repository_head(&head, repo) == 0) {
        git_reference_name_to_id(&currentHead, repo, "HEAD");
        char now[32];
        snprintf(now, sizeof(now), "%lld", static_cast<long long>(time(nullptr)));
        backtrackName = std::string("refs/backtrack/") + now;
        git_reference *written = nullptr;
        git_reference_create(&written, repo, backtrackName.c_str(), &currentHead, 1, nullptr);
        if (written != nullptr) {
            git_reference_free(written);
        }
        git_reference_free(head);
    }

    size_t deleted = 0;
    git_status_options opts = GIT_STATUS_OPTIONS_INIT;
    opts.show = GIT_STATUS_SHOW_WORKDIR_ONLY;
    opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    git_status_list *before = nullptr;
    if (git_status_list_new(&before, repo, &opts) == 0) {
        size_t count = git_status_list_entrycount(before);
        for (size_t i = 0; i < count; i++) {
            const git_status_entry *entry = git_status_byindex(before, i);
            if (entry == nullptr || (entry->status & GIT_STATUS_WT_NEW) == 0) {
                continue;
            }
            const char *path = entry->index_to_workdir != nullptr
                && entry->index_to_workdir->new_file.path != nullptr
                ? entry->index_to_workdir->new_file.path : nullptr;
            if (path == nullptr) {
                continue;
            }
            std::string full = projectDir + "/" + path;
            if (unlink(full.c_str()) == 0) {
                deleted++;
            }
        }
        git_status_list_free(before);
    }

    if (git_reset(repo, target, GIT_RESET_HARD, nullptr) != 0) {
        git_object_free(target);
        git_repository_free(repo);
        return ErrorJson("reset failed");
    }

    // 复位后再刷一次 index，让下一次快照看到的是复位后的状态。
    git_index *index = nullptr;
    if (git_repository_index(&index, repo) == 0) {
        git_index_read(index, 1);
        git_index_free(index);
    }

    char targetSha[GIT_OID_HEXSZ + 1] = {0};
    git_oid_tostr(targetSha, sizeof(targetSha), git_object_id(target));
    git_object_free(target);
    git_repository_free(repo);
    return std::string("{\"sha\":\"") + targetSha + "\",\"deleted\":" + std::to_string(deleted)
        + ",\"backtrack\":\"" + JsonEscape(backtrackName) + "\"}";
}

// 落快照要遍历整个工作树，在主线程做会阻塞超过三秒，系统直接判冻结并杀进程
// （实测 THREAD_BLOCK_3S + appfreeze）。所以放到 napi_async_work 的工作线程里跑。
struct CommitJob {
    std::string snapshotsDir;
    std::string projectDir;
    std::string message;
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void ExecuteCommit(napi_env env, void *data)
{
    CommitJob *job = static_cast<CommitJob *>(data);
    job->result = SnapshotCommit(job->snapshotsDir, job->projectDir, job->message);
}

void CompleteCommit(napi_env env, napi_status status, void *data)
{
    CommitJob *job = static_cast<CommitJob *>(data);
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

napi_value SnapCommitEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return MakeString(env, "{\"error\":\"snapshotsDir, projectDir and message are required\"}");
    }
    CommitJob *job = new CommitJob();
    job->snapshotsDir = ArgString(env, args[0]);
    job->projectDir = ArgString(env, args[1]);
    job->message = ArgString(env, args[2]);

    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "navi:snapshotCommit", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteCommit, CompleteCommit, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

struct ListJob {
    std::string snapshotsDir;
    std::string projectDir;
    int limit = 20;
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void ExecuteList(napi_env env, void *data)
{
    ListJob *job = static_cast<ListJob *>(data);
    job->result = SnapshotList(job->snapshotsDir, job->projectDir, job->limit);
}

void CompleteList(napi_env env, napi_status status, void *data)
{
    ListJob *job = static_cast<ListJob *>(data);
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

napi_value SnapListEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MakeString(env, "{\"error\":\"snapshotsDir and projectDir are required\"}");
    }
    ListJob *job = new ListJob();
    job->snapshotsDir = ArgString(env, args[0]);
    job->projectDir = ArgString(env, args[1]);
    if (argc >= 3) {
        int32_t value = 0;
        if (napi_get_value_int32(env, args[2], &value) == napi_ok && value > 0) {
            job->limit = value > 200 ? 200 : value;
        }
    }
    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "navi:snapshotList", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteList, CompleteList, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

struct RestoreJob {
    std::string snapshotsDir;
    std::string projectDir;
    std::string sha;
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void ExecuteRestore(napi_env env, void *data)
{
    RestoreJob *job = static_cast<RestoreJob *>(data);
    job->result = SnapshotRestore(job->snapshotsDir, job->projectDir, job->sha);
}

void CompleteRestore(napi_env env, napi_status status, void *data)
{
    RestoreJob *job = static_cast<RestoreJob *>(data);
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

napi_value SnapRestoreEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return MakeString(env, "{\"error\":\"snapshotsDir, projectDir and sha are required\"}");
    }
    RestoreJob *job = new RestoreJob();
    job->snapshotsDir = ArgString(env, args[0]);
    job->projectDir = ArgString(env, args[1]);
    job->sha = ArgString(env, args[2]);
    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "navi:snapshotRestore", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteRestore, CompleteRestore, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

}  // namespace


// 一个步骤的快照在写文件之前落，那时还不知道这一步会用什么工具、改几个文件。
// 等这一步结束再改写那条 commit 的 message，把三段补全——树不动，只换 message。
std::string SnapshotAnnotate(const std::string &snapshotsDir, const std::string &projectDir,
    const std::string &message)
{
    git_repository *repo = nullptr;
    int rc = OpenSnapshots(snapshotsDir, projectDir, &repo);
    if (rc != 0) {
        return ErrorJson("snapshot open failed");
    }
    git_reference *head = nullptr;
    if (git_repository_head(&head, repo) != 0) {
        git_repository_free(repo);
        return std::string("{\"error\":\"no snapshot to annotate\"}");
    }
    git_commit *current = nullptr;
    rc = git_reference_peel(reinterpret_cast<git_object **>(&current), head, GIT_OBJECT_COMMIT);
    if (rc != 0 || current == nullptr) {
        git_reference_free(head);
        git_repository_free(repo);
        return ErrorJson("head is not a commit");
    }
    git_tree *tree = nullptr;
    git_commit_tree(&tree, current);
    git_signature *sig = nullptr;
    git_signature_now(&sig, "rewind", "rewind@local");
    git_commit *parent = nullptr;
    git_commit *parents[1] = {nullptr};
    int parentCount = 0;
    if (git_commit_parentcount(current) > 0) {
        if (git_commit_parent(&parent, current, 0) == 0) {
            parents[0] = parent;
            parentCount = 1;
        }
    }
    git_oid amended;
    rc = git_commit_create(&amended, repo, "HEAD", sig, sig, nullptr, message.c_str(), tree,
        parentCount, parents);
    char sha[GIT_OID_HEXSZ + 1] = {0};
    if (rc == 0) {
        git_oid_tostr(sha, sizeof(sha), &amended);
    }
    if (parent != nullptr) {
        git_commit_free(parent);
    }
    git_signature_free(sig);
    git_tree_free(tree);
    git_commit_free(current);
    git_reference_free(head);
    git_repository_free(repo);
    if (rc != 0) {
        return ErrorJson("annotate failed");
    }
    return std::string("{\"sha\":\"") + sha + "\"}";
}

struct AnnotateJob {
    std::string snapshotsDir;
    std::string projectDir;
    std::string message;
    std::string result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void ExecuteAnnotate(napi_env env, void *data)
{
    AnnotateJob *job = static_cast<AnnotateJob *>(data);
    job->result = SnapshotAnnotate(job->snapshotsDir, job->projectDir, job->message);
}

void CompleteAnnotate(napi_env env, napi_status status, void *data)
{
    AnnotateJob *job = static_cast<AnnotateJob *>(data);
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

napi_value SnapAnnotateEntry(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return MakeString(env, "{\"error\":\"snapshotsDir, projectDir and message are required\"}");
    }
    AnnotateJob *job = new AnnotateJob();
    job->snapshotsDir = ArgString(env, args[0]);
    job->projectDir = ArgString(env, args[1]);
    job->message = ArgString(env, args[2]);
    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "navi:snapshotAnnotate", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteAnnotate, CompleteAnnotate, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

void RegisterRewindNapi(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"snapshotCommit", nullptr, SnapCommitEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshotList", nullptr, SnapListEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshotRestore", nullptr, SnapRestoreEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshotAnnotate", nullptr, SnapAnnotateEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, 4, desc);
    OH_LOG_INFO(LOG_APP, "navi rewind exports=4");
}

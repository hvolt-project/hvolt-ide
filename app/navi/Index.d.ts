export const probe: () => string;
export const buildInProc: (filesDir: string) => string;
export const hvoltCall: (argvJson: string, cwd: string, filesDir: string) => string;
export const execProbe: (path: string) => string;
export const streamStart: (paramsJson: string, filesDir: string) => string;
export const streamRead: (handle: number, from: number, max: number) => string;
export const streamNext: (handle: number, from: number, max: number, waitMs: number) => string;
export const streamStop: (handle: number) => void;
export const sandboxProbe: (dir: string, cache: string) => string;
export const sandboxSh: (line: string, root: string) => string;
export const jsEval: (source: string, timeoutMs: number, memLimitMb: number) => string;
/** 起一个带工具桥的会话，返回 {status:'need'|'done'|'error', ...} 的 JSON 文本。 */
export const jsEvalBegin: (source: string, timeoutMs: number, memLimitMb: number) => string;
/** 把待办调用的结果灌回去继续执行。results 形如 [{"id":1,"result":"文本"}]。 */
export const jsEvalResume: (session: number, results: string) => string;
export const jsEvalAbort: (session: number) => string;

// git：项目仓库的只读操作，经 libgit2 在进程内执行。返回 JSON 文本，出错时带 error 字段。
//
// 只读 op 走 gitCall 一个入口：native 侧 RegisterGitNapi 只导出 6 个名字，status/log/diff/show
// 合进了 gitCall 的 op 分发，没有各自的符号。以前这里按名字逐个声明（gitStatus 等），声明在
// .d.ts 里所以编译通过，运行时链接到第一个缺失名字就整个模块失败——声明必须与真实导出一致。
export const gitVersion: () => string;
export const gitCall: (op: string, repoDir: string, first: string, second: string) => Promise<string>;
export const gitAdd: (repoDir: string, paths: string[]) => Promise<string>;
export const gitCommit: (repoDir: string, message: string) => Promise<string>;
export const gitBranch: (repoDir: string, name: string, force: boolean) => Promise<string>;
export const gitCheckout: (repoDir: string, ref: string) => Promise<string>;


// rewind：独立快照库，与项目自己的 .git 无关。
export const snapshotCommit: (snapshotsDir: string, projectDir: string, message: string) => Promise<string>;
export const snapshotList: (snapshotsDir: string, projectDir: string, limit: number) => Promise<string>;
export const snapshotAnnotate: (snapshotsDir: string, projectDir: string, message: string) => Promise<string>;
export const snapshotRestore: (snapshotsDir: string, projectDir: string, sha: string) => Promise<string>;

// rewind：把项目回退到某个操作节点。
//
// 节点存在独立的对象库里，与项目自己的 .git 无关：库里记录的是项目工作树的快照，项目
// 自己的提交历史一个字节都不读不写。两件事共用 libgit2，但对象库不同。
//
// 列节点是只读，approval 为 none；回退会改文件并让之后的上下文失效，approval 为 confirm。

import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext, requireProject } from './Files';
import { snapshotCommit, snapshotList, snapshotRestore } from 'libnavi.so';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['rewind_list', 'rewind_to'];


/** 快照库放应用沙箱，不进项目目录：项目里出现一个 .git 之外的仓库目录会让人困惑。 */
function snapshotsDir(projectDir: string): string {
  const cut = projectDir.lastIndexOf('/');
  const name = cut >= 0 ? projectDir.substring(cut + 1) : projectDir;
  // 两级都要建：libgit2 的 init 只建 .git 自身，父目录缺一级就报 No such file or directory。
  const root = getContext().filesDir + '/snapshots';
  const mine = root + '/' + name;
  try {
    if (!fs.accessSync(root)) {
      fs.mkdirSync(root);
    }
    if (!fs.accessSync(mine)) {
      fs.mkdirSync(mine);
    }
  } catch (e) {
    // 目录已存在或并发创建；后面的打开会给出真实错误。
  }
  return mine;
}

function argText(args: Record<string, Object>, key: string): string {
  const value = args[key];
  return value === undefined || value === null ? '' : value as string;
}

/** 引擎给的秒数换算成一句相对时间。超过一天就不再说「几小时前」，那对回退没有帮助。 */
function relativeTime(thenSeconds: number): string {
  if (thenSeconds <= 0) {
    return '未知时间';
  }
  const now = Math.floor(Date.now() / 1000);
  const delta = now - thenSeconds;
  if (delta < 60) {
    return delta <= 0 ? '刚刚' : String(delta) + ' 秒前';
  }
  if (delta < 3600) {
    return String(Math.floor(delta / 60)) + ' 分钟前';
  }
  if (delta < 86400) {
    return String(Math.floor(delta / 3600)) + ' 小时前';
  }
  return String(Math.floor(delta / 86400)) + ' 天前';
}

/**
 * 把引擎返回的节点 JSON 变成契约要求的行格式。
 *
 * message 的三段（step|tool|files）由落盘方写入；早期快照只有 step 一段，缺的段显示为 -，
 * 这样列表里不会出现空列把对齐挤乱。
 */
function formatNodes(raw: string): string {
  let parsed: Record<string, Object>;
  try {
    parsed = JSON.parse(raw) as Record<string, Object>;
  } catch (e) {
    return 'error: could not read the snapshot list';
  }
  const error = parsed['error'];
  if (error !== undefined && error !== null) {
    return 'error: ' + (error as string);
  }
  const nodes = parsed['nodes'] as Object[];
  if (nodes === undefined || nodes === null || nodes.length === 0) {
    return '还没有快照节点';
  }
  const lines: string[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i] as Record<string, Object>;
    const sha = node['sha'] as string;
    const summary = node['summary'] === undefined || node['summary'] === null
      ? '' : node['summary'] as string;
    const time = typeof node['time'] === 'number' ? node['time'] as number : 0;
    let step = '-';
    let tool = '-';
    let files = '-';
    const parts = summary.split('|');
    for (let j = 0; j < parts.length; j++) {
      const at = parts[j].indexOf('=');
      if (at <= 0) {
        continue;
      }
      const key = parts[j].substring(0, at);
      const value = parts[j].substring(at + 1);
      if (key === 'step') {
        step = value;
      } else if (key === 'tool') {
        tool = value;
      } else if (key === 'files') {
        files = value;
      }
    }
    lines.push(sha.substring(0, 8) + '  ' + step + '  ' + tool + '  ' + files + '  '
      + relativeTime(time));
  }
  return lines.join('\n');
}

export function registerRewindTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'rewind_list',
    description: 'List the project snapshots the harness took before each step, newest first. '
      + 'Each line is "<sha8> <step> <tool> <files> <time>" and the sha8 can be passed to rewind_to.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'limit': { 'type': 'number', 'description': 'How many nodes, default 20, max 200.' }
      },
      'required': []
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const raw = args['limit'];
      const limit = typeof raw === 'number' ? raw as number : 20;
      // The contract fixes the shape as one text line per node, not JSON: the reader is a model
      // scanning a list, and a line it can copy the sha8 out of beats a nested object.
      return snapshotList(snapshotsDir(root), root, limit)
        .then((raw_: string) => formatNodes(raw_));
    }
  });

  registry.register({
    name: 'rewind_to',
    description: 'Restore the project files to a snapshot node. Files changed since then are '
      + 'overwritten, files created since then are deleted, and the pre-rewind state is kept in a '
      + 'ref so the rewind itself can be undone. This never touches the project .git.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'sha': { 'type': 'string', 'description': 'Target node sha, full or at least 8 chars.' }
      },
      'required': ['sha']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const sha = argText(args, 'sha');
      if (sha.length < 8) {
        return Promise.resolve('error: sha must be at least 8 characters');
      }
      return snapshotRestore(snapshotsDir(root), root, sha);
    }
  });
}

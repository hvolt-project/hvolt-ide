// git：项目仓库的只读操作。
//
// 一个工具带 op 参数，而不是 status/diff/log/show 各占一个工具位：工具位与提示词长度都是
// 稀缺资源，git 本身也把几十个语义装进一个命令。
//
// 只有四个只读 op 在这里注册。写类 op（add/commit/branch/checkout）要等 C++ 侧实现就绪再
// 加进 enum；先声明却跑不通的 op 会让模型以为能用，那是掩盖式补丁。

import { ToolRegistry } from '../mcp/Registry';
import { FileContext, requireProject } from './Files';
import { gitAdd, gitBranch, gitCheckout, gitCall, gitCommit } from 'libnavi.so';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['git'];


interface ReadOp {
  /** 这一步能取到数据的 git 子操作。 */
  name: string;
}

const READ_OPS: ReadOp[] = [
  { name: 'status' },
  { name: 'diff' },
  { name: 'log' },
  { name: 'show' }
];

/** 写类 op：会改仓库状态，必须逐次确认。 */
const WRITE_OPS: ReadOp[] = [
  { name: 'add' },
  { name: 'commit' },
  { name: 'branch' },
  { name: 'checkout' },
  { name: 'fetch' },
  { name: 'push' },
  { name: 'clone' }
];

/** "user:password" for the native network ops; empty when neither is given. */
function credentialText(args: Record<string, Object>): string {
  const user = argText(args, 'user');
  if (user.length === 0) {
    return '';
  }
  return user + ':' + argText(args, 'password');
}

function isWriteOp(op: string): boolean {
  for (const entry of WRITE_OPS) {
    if (entry.name === op) {
      return true;
    }
  }
  return false;
}

function opName(args: Record<string, Object>): string {
  const raw = args['op'];
  return raw === undefined || raw === null ? '' : raw as string;
}

/** 读 op 里的字符串参数，缺省给空串。 */
function argText(args: Record<string, Object>, key: string): string {
  const bag = args['args'];
  if (bag === undefined || bag === null) {
    return '';
  }
  const value = (bag as Record<string, Object>)[key];
  return value === undefined || value === null ? '' : value as string;
}

function argNumber(args: Record<string, Object>, key: string, fallback: number): number {
  const bag = args['args'];
  if (bag === undefined || bag === null) {
    return fallback;
  }
  const value = (bag as Record<string, Object>)[key];
  return typeof value === 'number' ? value as number : fallback;
}

/** add 用的路径列表；缺省给空数组，表示全部。 */
function argPaths(args: Record<string, Object>): string[] {
  const bag = args['args'];
  const out: string[] = [];
  if (bag === undefined || bag === null) {
    return out;
  }
  const value = (bag as Record<string, Object>)['paths'];
  if (value === undefined || value === null) {
    return out;
  }
  const list = value as Object[];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    if (typeof item === 'string') {
      out.push(item as string);
    }
  }
  return out;
}

function argFlag(args: Record<string, Object>, key: string): boolean {
  const bag = args['args'];
  if (bag === undefined || bag === null) {
    return false;
  }
  const value = (bag as Record<string, Object>)[key];
  return value === true;
}

export function registerGitTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'git',
    description: 'Read or change the project repository. Read ops: status, diff, log, show '
      + '(no network, no writes). Write ops: add, commit, branch, checkout — each one asks for '
      + 'confirmation first.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'op': {
          'type': 'string',
          'enum': ['status', 'diff', 'log', 'show', 'add', 'commit', 'branch', 'checkout', 'fetch', 'push', 'clone'],
          'description': 'Which git read operation to run.'
        },
        'args': {
          'type': 'object',
          'description': 'diff: {path?, staged?}; log: {limit?}; show: {sha}.',
          'properties': {
            'path': { 'type': 'string', 'description': 'Limit diff to one path.' },
            'staged': { 'type': 'boolean', 'description': 'Diff the index against HEAD.' },
            'limit': { 'type': 'number', 'description': 'log: how many commits, default 20, max 200.' },
            'sha': { 'type': 'string', 'description': 'show: commit sha, full or abbreviated.' },
            'paths': {
              'type': 'array',
              'description': 'add: paths to stage; empty means everything.',
              'items': { 'type': 'string' }
            },
            'message': { 'type': 'string', 'description': 'commit: message text.' },
            'name': { 'type': 'string', 'description': 'branch: branch name.' },
            'force': { 'type': 'boolean', 'description': 'branch: overwrite when it exists.' },
            'ref': { 'type': 'string', 'description': 'checkout: branch or commit to switch to.' },
            'url': { 'type': 'string', 'description': 'clone: remote url to clone from (https only).' },
            'refspec': { 'type': 'string', 'description': 'push: refspec; empty means the current branch to origin.' },
            'user': { 'type': 'string', 'description': 'fetch/push/clone: https user, optional.' },
            'password': { 'type': 'string', 'description': 'fetch/push/clone: https password or token, optional.' }
          },
          'required': []
        }
      },
      'required': ['op']
    },
    approval: (args: Record<string, Object>): string => {
      // 读 op 不问，写 op 每次问：同一个工具里两种风险等级，按这次调用的 op 决定。
      return isWriteOp(opName(args)) ? 'confirm' : 'none';
    },
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const op = opName(args);
      // 四个只读 op 共用 gitCall 一个 native 入口：native 只导出 gitCall，没有各自的名字符号。
      if (op === 'status') {
        return gitCall('status', root, '', '');
      }
      if (op === 'log') {
        return gitCall('log', root, String(argNumber(args, 'limit', 20)), '');
      }
      if (op === 'diff') {
        return gitCall('diff', root, argText(args, 'path'), argFlag(args, 'staged') ? 'staged' : '');
      }
      if (op === 'show') {
        const sha = argText(args, 'sha');
        if (sha.length === 0) {
          return Promise.resolve('error: show needs args.sha');
        }
        return gitCall('show', root, sha, '');
      }
      if (op === 'add') {
        return gitAdd(root, argPaths(args));
      }
      if (op === 'commit') {
        const message = argText(args, 'message');
        if (message.length === 0) {
          return Promise.resolve('error: commit needs args.message');
        }
        return gitCommit(root, message);
      }
      if (op === 'branch') {
        const name = argText(args, 'name');
        if (name.length === 0) {
          return Promise.resolve('error: branch needs args.name');
        }
        return gitBranch(root, name, argFlag(args, 'force'));
      }
      if (op === 'checkout') {
        const ref = argText(args, 'ref');
        if (ref.length === 0) {
          return Promise.resolve('error: checkout needs args.ref');
        }
        return gitCheckout(root, ref);
      }
      // The network ops share one native entry; credentials ride along as "user:password" in the
      // fourth slot, which the native side splits on the first colon.
      if (op === 'fetch') {
        return gitCall('fetch', root, '', credentialText(args));
      }
      if (op === 'push') {
        return gitCall('push', root, argText(args, 'refspec'), credentialText(args));
      }
      if (op === 'clone') {
        const url = argText(args, 'url');
        const dest = argText(args, 'path');
        if (url.length === 0 || dest.length === 0) {
          return Promise.resolve('error: clone needs args.url and args.path');
        }
        return gitCall('clone', url, dest, credentialText(args));
      }
      const known: string[] = [];
      for (const entry of READ_OPS) {
        known.push(entry.name);
      }
      for (const entry of WRITE_OPS) {
        known.push(entry.name);
      }
      return Promise.resolve('error: unknown op "' + op + '", expected one of ' + known.join(', '));
    }
  });
}

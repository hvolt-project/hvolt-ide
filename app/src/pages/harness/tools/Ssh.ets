// ssh：设备侧的远程连接，独立能力 so，与 libnavi.so 平行。
//
// 会话是 handle 模式：open 一次、exec 多次、close 一次。连接建立后复用同一条 TCP 与同一个
// ssh session；每次 exec 只开一个 channel，不重复握手。
//
// 这个模块不 import 时不会加载：so 缺失的那一句 import 直接失败，注册函数据此决定不注册
// ssh 工具（见 capability-and-ssh-decisions.md「能力 so 缺失时的行为」）。

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { sshCall } from 'libnavi_ssh.so';
import { generateKeyPair, publicKeyPath, privateKeyPath } from './SshKey';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['ssh'];

interface SshOpenArgs {
  host: string;
  port: number;
  user: string;
  password: string;
  key: string;
  pubkey: string;
  confirm_only: boolean;
}

function argText(args: Record<string, Object>, key: string): string {
  const value = args[key];
  return value === undefined || value === null ? '' : value as string;
}

function argNumber(args: Record<string, Object>, key: string, fallback: number): number {
  const value = args[key];
  return typeof value === 'number' ? value as number : fallback;
}

function argFlag(args: Record<string, Object>, key: string): boolean {
  return args[key] === true;
}

/** 把工具参数摊成 sshCall 的位置参数。 */
function callOpen(bag: Record<string, Object>): Promise<string> {
  const args: SshOpenArgs = {
    host: argText(bag, 'host'),
    port: argNumber(bag, 'port', 22),
    user: argText(bag, 'user'),
    password: argText(bag, 'password'),
    key: argText(bag, 'key'),
    pubkey: argText(bag, 'pubkey'),
    confirm_only: argFlag(bag, 'confirm_only')
  };
  if (args.host.length === 0) {
    return Promise.resolve('error: open needs args.host');
  }
  if (!args.confirm_only && args.user.length === 0) {
    return Promise.resolve('error: open needs args.user');
  }
  // 认证方式二选一：密码为空则走私钥，两者都空时引擎会报 no credentials given。
  return sshCall('open', args.host, String(args.port), args.user, args.password, args.key,
    args.pubkey, args.confirm_only ? '1' : '0');
}

function callExec(bag: Record<string, Object>): Promise<string> {
  const handle = argNumber(bag, 'handle', -1);
  const command = argText(bag, 'command');
  if (handle < 0) {
    return Promise.resolve('error: exec needs args.handle (from ssh open)');
  }
  if (command.length === 0) {
    return Promise.resolve('error: exec needs args.command');
  }
  return sshCall('exec', String(handle), command, '', '', '', '', '');
}

function callClose(bag: Record<string, Object>): Promise<string> {
  const handle = argNumber(bag, 'handle', -1);
  if (handle < 0) {
    return Promise.resolve('error: close needs args.handle');
  }
  return sshCall('close', String(handle), '', '', '', '', '', '');
}

export function registerSshTools(registry: ToolRegistry): void {
  registry.register({
    name: 'ssh',
    description: 'Run commands on a remote host over ssh from this device. open returns a handle '
      + 'that exec reuses, so a session is one connection rather than one handshake per command. '
      + 'open with confirm_only=true talks to the host without authenticating and returns its '
      + 'SHA256 host key fingerprint — check it before trusting a new host.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'op': {
          'type': 'string',
          'enum': ['open', 'exec', 'close', 'version', 'keygen', 'pubkey', 'sftp_read', 'sftp_write', 'sftp_list', 'forward', 'forward_stop'],
          'description': 'open a session, run a command in it, transfer files with sftp, or close it. keygen makes this device its own Ed25519 key inside the sandbox; pubkey prints the line to paste into the target\'s authorized_keys.'
        },
        'args': {
          'type': 'object',
          'description': 'open: host/port/user/password|key/confirm_only; exec: handle/command; '
            + 'close: handle.',
          'properties': {
            'host': { 'type': 'string', 'description': 'Hostname or address.' },
            'port': { 'type': 'number', 'description': 'Port, default 22.' },
            'user': { 'type': 'string', 'description': 'Login user.' },
            'password': { 'type': 'string', 'description': 'Password; empty means use key.' },
            'key': { 'type': 'string', 'description': 'Path to a private key in the app sandbox.' },
            'pubkey': { 'type': 'string', 'description': 'Path to the matching public key.' },
            'confirm_only': {
              'type': 'boolean',
              'description': 'Only handshake and report the host key fingerprint.'
            },
            'handle': { 'type': 'number', 'description': 'Session handle from open.' },
            'command': { 'type': 'string', 'description': 'Command line to run on the host.' },
            'path': { 'type': 'string', 'description': 'sftp: remote path.' },
            'text': { 'type': 'string', 'description': 'sftp_write: file content.' },
            'remote_host': { 'type': 'string', 'description': 'forward: destination host as the '
              + 'remote side sees it.' },
            'remote_port': { 'type': 'number', 'description': 'forward: destination port.' },
            'local_port': { 'type': 'number', 'description': 'forward: port to listen on, 0 picks '
              + 'a free one and reports it.' },
            'forward': { 'type': 'number', 'description': 'forward_stop: id from forward.' }
          },
          'required': []
        }
      },
      'required': ['op']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const op = argText(args, 'op');
      const bag = args['args'];
      if (op === 'version') {
        return sshCall('version', '', '', '', '', '', '', '');
      }
      if (op === 'keygen') {
        return generateKeyPair(getContext().filesDir).then((out: string) => {
          return out;
        });
      }
      if (op === 'pubkey') {
        // 把已生成的那一行读出来，方便贴到目标机的 authorized_keys。
        try {
          const file = fs.openSync(publicKeyPath(getContext().filesDir), fs.OpenMode.READ_ONLY);
          const text = fs.readTextSync(publicKeyPath(getContext().filesDir));
          fs.closeSync(file);
          return Promise.resolve(text.trim());
        } catch (e) {
          return Promise.resolve('error: no key yet, run ssh(op=keygen) first');
        }
      }
      if (bag === undefined || bag === null) {
        return Promise.resolve('error: "' + op + '" needs args');
      }
      const fields = bag as Record<string, Object>;
      if (op === 'open') {
        return callOpen(fields);
      }
      if (op === 'exec') {
        return callExec(fields);
      }
      if (op === 'close') {
        return callClose(fields);
      }
      if (op === 'forward') {
        const handle = argNumber(fields, 'handle', -1);
        const remoteHost = argText(fields, 'remote_host');
        const remotePort = argNumber(fields, 'remote_port', 0);
        const localPort = argNumber(fields, 'local_port', 0);
        if (handle < 0) {
          return Promise.resolve('error: forward needs args.handle');
        }
        if (remoteHost.length === 0 || remotePort <= 0) {
          return Promise.resolve('error: forward needs args.remote_host and args.remote_port');
        }
        return sshCall('forward', String(handle), String(localPort), remoteHost,
          String(remotePort), '', '', '');
      }
      if (op === 'forward_stop') {
        const id = argNumber(fields, 'forward', -1);
        if (id < 0) {
          return Promise.resolve('error: forward_stop needs args.forward');
        }
        return sshCall('forward_stop', String(id), '', '', '', '', '', '');
      }
      if (op === 'sftp_read' || op === 'sftp_write' || op === 'sftp_list') {
        const handle = argNumber(fields, 'handle', -1);
        const path = argText(fields, 'path');
        if (handle < 0) {
          return Promise.resolve('error: ' + op + ' needs args.handle');
        }
        if (path.length === 0 && op !== 'sftp_list') {
          return Promise.resolve('error: ' + op + ' needs args.path');
        }
        const text = op === 'sftp_write' ? argText(fields, 'text') : '';
        return sshCall(op, String(handle), path.length === 0 ? '.' : path, text, '', '', '');
      }
      return Promise.resolve('error: unknown op "' + op + '", expected open, exec, close, version');
    }
  });
}

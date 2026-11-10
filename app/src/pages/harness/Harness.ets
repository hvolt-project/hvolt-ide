// Registration point for the MCP endpoint. Every tool is listed here once; nothing else knows
// the tool names.

import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { McpServer } from './mcp/Server';
import { TOOLS, ToolRegistry } from './mcp/Registry';
import { FileContext, registerFileTools } from './tools/Files';
import { registerWriteTool } from './tools/Write';
import { registerEditTool } from './tools/Edit';
import { registerBuildTools } from './tools/Build';
import { registerDeployTool } from './tools/Deploy';
import { registerLogTools } from './tools/Logs';
import { registerDeviceTools } from './tools/Device';
import { installApprovalGate } from './Approval';

/** Port the loopback endpoint binds to; the built-in client uses the same number. */
export const MCP_PORT: number = 8765;

/** Protocol self-check: proves the listener, framing and dispatch without touching device state. */
function registerPing(): void {
  TOOLS.register({
    name: 'ping',
    description: 'Returns the given text unchanged. Used to verify the endpoint end to end.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': { 'type': 'string', 'description': 'Text to echo back.' }
      },
      'required': ['text']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const text = args['text'];
      return Promise.resolve('pong:' + (text === undefined ? '' : text as string));
    }
  });
}

// Proves binding, framing, dispatch and both reply paths by calling the endpoint it just
// started: one listing, one known tool, one unknown tool.
let probeRoot: () => string = () => '';

function ctxProjectDir(): string {
  return probeRoot();
}

async function selfCheck(port: number, projectDir: () => string): Promise<void> {
  probeRoot = projectDir;
  const client = socket.constructTCPSocketInstance();
  const decoder = util.TextDecoder.create('utf-8');
  const inbox: string[] = [];

  // One datagram may carry several replies: split on newlines so the count matches requests.
  client.on('message', (info: socket.SocketMessageInfo) => {
    const text = decoder.decodeToString(new Uint8Array(info.message));
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.length > 0) {
        inbox.push(trimmed);
      }
    }
  });

  const waitFor = async (count: number): Promise<string[]> => {
    const deadline = Date.now() + 3000;
    while (inbox.length < count && Date.now() < deadline) {
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 20);
      });
    }
    return inbox;
  };

  try {
    const target: socket.TCPConnectOptions = {
      address: { address: '127.0.0.1', port: port, family: 1 }
    };
    await client.connect(target);
    const call = (id: string, name: string, args: Record<string, Object>): string => {
      return JSON.stringify({
        'jsonrpc': '2.0', 'id': id, 'method': 'tools/call',
        'params': { 'name': name, 'arguments': args }
      });
    };
    const calls: string[] = [
      JSON.stringify({ 'jsonrpc': '2.0', 'id': 'list', 'method': 'tools/list', 'params': {} }),
      call('ping', 'ping', { 'text': 'ok' }),
      call('missing', 'no-such-tool', {}),
      call('glob', 'glob', { 'pattern': '**/*.ets' }),
      call('grep', 'grep', { 'pattern': 'hvolt', 'include': '**/*.ets' }),
      call('read', 'read', { 'path': 'hvolt.toml' }),
      call('write', 'write', { 'path': 'harness-probe.txt', 'content': 'a\nb\na' }),
      call('readback', 'read', { 'path': 'harness-probe.txt' }),
      call('editdup', 'edit', { 'path': 'harness-probe.txt', 'old_string': 'a', 'new_string': 'z' }),
      call('log', 'read_log', { 'lines': 3 }),
      call('devices', 'devices', {}),
      call('shellgate', 'shell', { 'command': 'echo hi' })
    ];
    for (const body of calls) {
      await client.send({ data: body + '\n' });
    }
    const replies = await waitFor(calls.length);
    for (const reply of replies) {
      hilog.info(0x0000, 'hvoltide', 'mcp selfcheck: %{public}s', reply.substring(0, 220));
    }
  } catch (e) {
    hilog.warn(0x0000, 'hvoltide', 'mcp selfcheck failed: %{public}s', (e as Error).message);
  } finally {
    client.close().catch(() => {
    });
    // The probe file exists only to prove write/read/edit agree; leave no litter behind.
    const probe = ctxProjectDir() + '/harness-probe.txt';
    try {
      fs.unlinkSync(probe);
    } catch (e) {
    }
  }
}

let running: McpServer | undefined = undefined;

/** Starts the endpoint once. Failures are logged, never thrown at the caller: an IDE that cannot
 *  host the endpoint still works as an editor. */
export function startHarness(ctx: FileContext, registry: ToolRegistry = TOOLS): void {
  if (running !== undefined) {
    return;
  }
  registerPing();
  registerFileTools(registry, ctx);
  registerWriteTool(registry, ctx);
  registerEditTool(registry, ctx);
  registerBuildTools(registry, ctx);
  registerDeployTool(registry, ctx);
  registerLogTools(registry, ctx);
  registerDeviceTools(registry, ctx);
  installApprovalGate();
  const server = new McpServer();
  server.start(registry, MCP_PORT).then(() => {
    running = server;
    selfCheck(MCP_PORT, ctx.projectDir).catch(() => {
    });
  }).catch((e: Error) => {
    hilog.warn(0x0000, 'hvoltide', 'mcp endpoint unavailable: %{public}s', e.message);
  });
}

export function stopHarness(): void {
  const server = running;
  running = undefined;
  if (server !== undefined) {
    server.stop().catch(() => {
    });
  }
}

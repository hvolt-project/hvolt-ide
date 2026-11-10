// Registration point for the MCP endpoint. Every tool is listed here once; nothing else knows
// the tool names.

import hilog from '@ohos.hilog';
import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { McpServer } from './mcp/Server';
import { TOOLS, ToolRegistry } from './mcp/Registry';

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
async function selfCheck(port: number): Promise<void> {
  const client = socket.constructTCPSocketInstance();
  const decoder = util.TextDecoder.create('utf-8');
  const inbox: string[] = [];

  client.on('message', (info: socket.SocketMessageInfo) => {
    inbox.push(decoder.decodeToString(new Uint8Array(info.message)).trim());
  });

  const waitFor = async (count: number): Promise<string[]> => {
    while (inbox.length < count) {
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
    const calls: string[] = [
      JSON.stringify({ 'jsonrpc': '2.0', 'id': 'list', 'method': 'tools/list', 'params': {} }),
      JSON.stringify({
        'jsonrpc': '2.0', 'id': 'ping', 'method': 'tools/call',
        'params': { 'name': 'ping', 'arguments': { 'text': 'ok' } }
      }),
      JSON.stringify({
        'jsonrpc': '2.0', 'id': 'missing', 'method': 'tools/call',
        'params': { 'name': 'no-such-tool', 'arguments': {} }
      })
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
  }
}

let running: McpServer | undefined = undefined;

/** Starts the endpoint once. Failures are logged, never thrown at the caller: an IDE that cannot
 *  host the endpoint still works as an editor. */
export function startHarness(registry: ToolRegistry = TOOLS): void {
  if (running !== undefined) {
    return;
  }
  registerPing();
  const server = new McpServer();
  server.start(registry, MCP_PORT).then(() => {
    running = server;
    selfCheck(MCP_PORT).catch(() => {
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

// Loopback transport for the MCP endpoint: one TCP listener on 127.0.0.1, newline-delimited
// JSON-RPC frames. Transport only — it decodes, hands text to the protocol layer and writes the
// reply back; it never inspects methods or tools.

import socket from '@ohos.net.socket';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { handleMessage } from './Protocol';
import { ToolRegistry } from './Registry';

const DOMAIN: number = 0x0000;
const TAG: string = 'hvoltide';

class FrameBuffer {
  private pending: string = '';

  /** Returns every complete line in the buffer, keeping the trailing partial one. */
  push(chunk: string): string[] {
    this.pending += chunk;
    const lines: string[] = [];
    let cut = this.pending.indexOf('\n');
    while (cut >= 0) {
      const line = this.pending.substring(0, cut).trim();
      if (line.length > 0) {
        lines.push(line);
      }
      this.pending = this.pending.substring(cut + 1);
      cut = this.pending.indexOf('\n');
    }
    return lines;
  }
}

export class McpServer {
  private server: socket.TCPSocketServer | undefined = undefined;
  private port: number = 0;

  /** Binds and starts accepting. Throws with the OS message when the port is taken. */
  async start(registry: ToolRegistry, port: number): Promise<void> {
    if (this.server !== undefined) {
      return;
    }
    const listener = socket.constructTCPSocketServerInstance();
    listener.on('connect', (client: socket.TCPSocketConnection) => {
      this.serve(registry, client);
    });
    const address: socket.NetAddress = { address: '127.0.0.1', port: port, family: 1 };
    await listener.listen(address);
    this.server = listener;
    this.port = port;
    hilog.info(DOMAIN, TAG, 'mcp listening on 127.0.0.1:%{public}d', port);
  }

  private serve(registry: ToolRegistry, client: socket.TCPSocketConnection): void {
    const frames = new FrameBuffer();
    const decoder = util.TextDecoder.create('utf-8');
    client.on('message', (info: socket.SocketMessageInfo) => {
      const chunk = decoder.decodeToString(new Uint8Array(info.message));
      for (const line of frames.push(chunk)) {
        handleMessage(registry, line).then((outcome) => {
          if (outcome.body.length === 0) {
            return;
          }
          client.send({ data: outcome.body + '\n' }).catch((e: Error) => {
            hilog.warn(DOMAIN, TAG, 'mcp send failed: %{public}s', e.message);
          });
        });
      }
    });
  }

  async stop(): Promise<void> {
    if (this.server === undefined) {
      return;
    }
    await this.server.close();
    this.server = undefined;
    this.port = 0;
  }

  listening(): number {
    return this.port;
  }
}

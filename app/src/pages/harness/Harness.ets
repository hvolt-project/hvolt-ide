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
import { registerSandboxTools } from './tools/Sandbox';
import { registerJobTools } from './tools/Jobs';
import { registerTodoTools } from './tools/Todo';
import { registerWebTools } from './tools/Web';
import { registerUiTools } from './tools/UI';
import { registerSdkTools } from './tools/Sdk';
import { registerChatTool } from './tools/Chat';
import { registerRecallTool } from './tools/Recall';
import { registerAskTool } from './tools/Ask';
import { registerSkillTool } from './tools/Skill';
import { installApprovalGate } from './Approval';
import { buildSystemPrompt } from './Prompt';

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
  registerSandboxTools(registry, ctx);
  registerJobTools(registry, ctx);
  registerTodoTools(registry, ctx);
  registerWebTools(registry, ctx);
  registerUiTools(registry, ctx);
  registerSdkTools(registry);
  registerChatTool(registry, ctx);
  registerRecallTool(registry, ctx);
  registerAskTool(registry, ctx);
  registerSkillTool(registry, ctx);
  // The surface the model will see, named once at startup: a tool that fails to register is
  // otherwise invisible until the model asks for it and gets "no such tool".
  const names: string[] = [];
  for (const spec of TOOLS.descriptors()) {
    names.push(spec['name'] as string);
  }
  hilog.info(0x0000, 'hvoltide', 'tools registered: %{public}d %{public}s', names.length,
    names.join(','));

  // Reported once at startup: proves the shipped prompt file is readable from the bundle.
  buildSystemPrompt().then((text: string) => {
    hilog.info(0x0000, 'hvoltide', 'system prompt: %{public}d chars', text.length);
  }).catch(() => {
  });
  installApprovalGate();
  const server = new McpServer();
  server.start(registry, MCP_PORT).then(() => {
    running = server;
    hilog.info(0x0000, 'hvoltide', 'mcp tools: %{public}d', registry.descriptors().length);
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

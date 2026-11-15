// Device tools: the ones that reach the phone itself.
//
// `shell`, `start` and `screenshot` are marked confirm. The dispatcher reads that field and asks
// before running the handler, so nothing here has to remember to ask; a tool that forgets is still
// gated. Keeping the check in one place is what lets a tool decide per call.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { ToolRun, runHvolt } from './Build';
import { FILES } from '../../model/Stage';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['devices', 'shell', 'start', 'screenshot'];


function lastLines(text: string, lines: number): string {
  const all: string[] = text.split('\n');
  const start = all.length > lines ? all.length - lines : 0;
  return all.slice(start).join('\n');
}

export function registerDeviceTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'devices',
    description: 'List devices reachable over USB and the configured install target.',
    inputSchema: { 'type': 'object', 'properties': {}, 'required': [] },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      return runHvolt(['device', 'list'], ctx.projectDir()).then((run: ToolRun) => {
        return lastLines(run.output, 20);
      });
    }
  });

  registry.register({
    name: 'shell',
    description: 'Run one shell command on the connected device and return its output.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': { 'type': 'string', 'description': 'Command line to run on the device.' }
      },
      'required': ['command']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const command = args['command'] as string;
      return runHvolt(['shell', command], ctx.projectDir()).then((run: ToolRun) => {
        return lastLines(run.output, 60);
      });
    }
  });

  registry.register({
    name: 'start',
    description: 'Launch an installed bundle, optionally naming the ability.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'target': { 'type': 'string', 'description': 'bundle or bundle/ability.' }
      },
      'required': ['target']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const target = args['target'] as string;
      return runHvolt(['start', target], ctx.projectDir()).then((run: ToolRun) => {
        return lastLines(run.output, 10);
      });
    }
  });

  registry.register({
    name: 'screenshot',
    description: 'Capture the device screen into the project sandbox and return the file path.',
    inputSchema: { 'type': 'object', 'properties': {}, 'required': [] },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      // 截图落在应用沙箱，不落项目的 build/：那是构建产物目录，随手拍的图混进去
      // 会跟着打包和清理一起走。沙箱里的固定名也让下一轮能重复覆盖，不留一堆。
      const path = FILES + '/screenshot.jpeg';
      return runHvolt(['screenshot', '-o', path], ctx.projectDir()).then((run: ToolRun) => {
        return 'screenshot code=' + run.code + ' -> ' + path + '\n' + lastLines(run.output, 5);
      });
    }
  });
}

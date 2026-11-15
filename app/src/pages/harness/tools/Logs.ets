// Reading the device log from the tool side.
//
// The persisted copies under /data/log/hilog are the reason a backgrounded or killed IDE still
// has history: hilog -w writes them regardless of who is watching. They live outside the sandbox,
// so the read goes through the device shell rather than the file API.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { ToolRun, runHvolt } from './Build';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['read_log'];


const DEFAULT_LINES: number = 50;
const MAX_LINES: number = 200;

/** Rejects anything that would break out of the single-quoted shell argument. */
function shellSafe(text: string): string {
  if (text.indexOf("'") >= 0) {
    throw new Error('pattern must not contain single quotes: ' + text);
  }
  return text;
}

function clampLines(value: number): number {
  if (value <= 0) {
    return DEFAULT_LINES;
  }
  return value > MAX_LINES ? MAX_LINES : value;
}

export function registerLogTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'read_log',
    description: 'Read recent device logs from the persisted hilog files, optionally filtered by text.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': { 'type': 'string', 'description': 'Plain text the line must contain.' },
        'lines': { 'type': 'number', 'description': 'How many trailing lines to return (max 200).' }
      },
      'required': []
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      // Reading the device log needs no project: cwd is only where the shell runs.
      const root = ctx.projectDir();
      const lines = clampLines(args['lines'] === undefined ? DEFAULT_LINES : args['lines'] as number);
      const pattern = args['pattern'] === undefined ? '' : shellSafe(args['pattern'] as string);

      // 归档的 /data/log/hilog/*.gz 是 hilog 自己的二进制记录格式：zcat 解出来仍是带二进制头
      // 的行，当文本 tail 会吐乱码（实测 3MB 输出里混着记录头）。改让 hilog 自己 dump——输出
      // 是标准文本，时间、级别、tag 都在，也不需要先找文件名。
      const filter = pattern.length === 0 ? '' : ' | grep -F \'' + pattern + '\'';
      const command = 'hilog -x 2>/dev/null' + filter + ' | tail -' + lines;
      return runHvolt(['shell', command], root).then((run: ToolRun) => {
        const body = run.output.trim();
        return body.length === 0 ? '(no matching lines in the device log)' : body;
      });
    }
  });
}

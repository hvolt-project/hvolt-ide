// Reading the device log from the tool side.
//
// The persisted copies under /data/log/hilog are the reason a backgrounded or killed IDE still
// has history: hilog -w writes them regardless of who is watching. They live outside the sandbox,
// so the read goes through the device shell rather than the file API.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { ToolRun, runHvolt } from './Build';

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

      return runHvolt(['shell', 'ls -t /data/log/hilog/hilog.*.gz | head -3'], root)
        .then((listing: ToolRun) => {
          const files: string[] = listing.output.split('\n')
            .map((line: string) => line.trim())
            .filter((line: string) => line.length > 0 && line.endsWith('.gz'));
          if (files.length === 0) {
            return 'no persisted log files under /data/log/hilog';
          }
          const filter = pattern.length === 0 ? '' : ' | grep -F \'' + pattern + '\'';
          const command = 'zcat ' + files.join(' ') + filter + ' | tail -' + lines;
          return runHvolt(['shell', command], root).then((run: ToolRun) => {
            const body = run.output.trim();
            return body.length === 0 ? '(no matching lines in ' + files.length + ' file(s))' : body;
          });
        });
    }
  });
}

// Build-chain tools. They only orchestrate: the toolchain itself is the native hvolt library,
// reached through the same worker bridge the shell uses. Nothing here reimplements a step.

import { hvoltAsync } from '../../model/Connect';
import { FILES } from '../../model/Stage';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext, requireProject } from './Files';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['build'];


export interface ToolRun {
  code: number;
  output: string;
}

/** One hvolt command, resolved from the envelope the worker returns. */
export function runHvolt(argv: string[], cwd: string): Promise<ToolRun> {
  return new Promise<ToolRun>((resolve) => {
    hvoltAsync(argv, cwd, FILES, (raw: string) => {
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        const codeValue = parsed['code'];
        const outputValue = parsed['output'];
        resolve({
          code: codeValue === undefined ? -1 : codeValue as number,
          output: outputValue === undefined ? raw : outputValue as string
        });
      } catch (e) {
        resolve({ code: -1, output: raw.substring(0, 400) });
      }
    });
  });
}

/** Last lines of toolchain output: the interesting part of a build is at the end. */
function tail(text: string, lines: number): string {
  const all: string[] = text.split('\n');
  const start = all.length > lines ? all.length - lines : 0;
  return all.slice(start).join('\n');
}

export function registerBuildTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'build',
    description: 'Build the open project with hvolt. Returns the exit code and the tail of its output.',
    inputSchema: {
      'type': 'object',
      'properties': {},
      'required': []
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      return runHvolt(['build'], root).then((run: ToolRun) => {
        return 'build code=' + run.code + '\n' + tail(run.output, 40);
      });
    }
  });
}

// Deploy: provision materials, build (which signs against them), then install. Same order as the
// shell's deploy, for the same reason: hvolt only signs during build when the project already
// carries an [app.signing] table, and `sign` is what writes it.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext, requireProject } from './Files';
import { ToolRun, runHvolt } from './Build';

function lastLines(text: string, lines: number): string {
  const all: string[] = text.split('\n');
  const start = all.length > lines ? all.length - lines : 0;
  return all.slice(start).join('\n');
}

/** The package a build produced, or '' when it produced none. */
function signedPackage(root: string): string {
  let names: string[] = [];
  try {
    names = fs.listFileSync(root + '/build');
  } catch (e) {
    return '';
  }
  const signed = names.filter((name: string) => name.endsWith('-signed.hap'));
  return signed.length > 0 ? signed[0] : '';
}

export function registerDeployTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'sign_deploy',
    description: 'Provision signing materials, build the project and install it on the connected device.',
    inputSchema: {
      'type': 'object',
      'properties': {},
      'required': []
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      return runHvolt(['sign'], root).then((prepared: ToolRun) => {
        if (prepared.code !== 0) {
          return 'sign code=' + prepared.code + '\n' + lastLines(prepared.output, 20);
        }
        return runHvolt(['build'], root).then((built: ToolRun) => {
          if (built.code !== 0) {
            return 'build code=' + built.code + '\n' + lastLines(built.output, 30);
          }
          const signed = signedPackage(root);
          if (signed.length === 0) {
            return 'build ok but no signed package in build/; deploy stopped';
          }
          return runHvolt(['push', '--hap', 'build/' + signed], root).then((installed: ToolRun) => {
            return 'deployed ' + signed + ' code=' + installed.code + '\n' +
              lastLines(installed.output, 10);
          });
        });
      });
    }
  });
}

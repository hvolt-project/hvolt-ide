// Deploy: provision materials, build (which signs against them), then install. Same order as the
// shell's deploy, for the same reason: hvolt only signs during build when the project already
// carries an [app.signing] table, and `sign` is what writes it.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext, requireProject } from './Files';
import { ToolRun, runHvolt } from './Build';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['reinstall_self', 'sign_deploy'];


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

/**
 * Installing the IDE over itself.
 *
 * The reason this is its own tool: the package being installed is the one running the call, so the
 * process is stopped partway through. Whether the install itself survives that is the open question
 * — hvolt streams the bytes first and the daemon installs only after the last byte, so stopping the
 * caller should leave the package complete; this tool is how that gets measured rather than assumed.
 */
function registerReinstallTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'reinstall_self',
    description: 'Install the signed package built from the IDE\'s own unpacked source over the ' +
      'running app. The process is stopped by the install, so the call may not return. Diagnostic: ' +
      'it exists to prove that a self-install completes.',
    inputSchema: {
      'type': 'object',
      'properties': {},
      'required': []
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const locate = ctx.selfSourceDir;
      if (locate === undefined) {
        return Promise.resolve('self source is not available');
      }
      const root = locate();
      if (root.length === 0) {
        return Promise.resolve('the IDE source has not been unpacked yet');
      }
      const signed = signedPackage(root);
      if (signed.length === 0) {
        return Promise.resolve('no signed package in ' + root + '/build — build the source first');
      }
      return runHvolt(['push', '--hap', 'build/' + signed], root).then((installed: ToolRun) => {
        return 'self-install ' + signed + ' code=' + installed.code + '\n' + lastLines(installed.output, 10);
      });
    }
  });
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
  registerReinstallTool(registry, ctx);
}

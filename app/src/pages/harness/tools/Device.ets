// Device tools: the ones that reach the phone itself.
//
// `shell` and `start` are marked confirm. Until the approval gate is wired (I6) the gate is a
// function that refuses, so registering these tools cannot quietly run anything irreversible.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { ToolRun, runHvolt } from './Build';

export type ApprovalRequest = (tool: string, detail: string) => Promise<boolean>;

let gate: ApprovalRequest = () => Promise.resolve(false);

/** Installs the approval gate. Until this is called, confirming tools refuse to run. */
export function setApprovalGate(request: ApprovalRequest): void {
  gate = request;
}

function guarded(tool: string, detail: string): Promise<boolean> {
  return gate(tool, detail);
}

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
      return guarded('shell', command).then((allowed: boolean) => {
        if (!allowed) {
          return 'shell is awaiting approval (gate not wired yet)';
        }
        return runHvolt(['shell', command], ctx.projectDir()).then((run: ToolRun) => {
          return lastLines(run.output, 60);
        });
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
      return guarded('start', target).then((allowed: boolean) => {
        if (!allowed) {
          return 'start is awaiting approval (gate not wired yet)';
        }
        return runHvolt(['start', target], ctx.projectDir()).then((run: ToolRun) => {
          return lastLines(run.output, 10);
        });
      });
    }
  });

  registry.register({
    name: 'screenshot',
    description: 'Capture the device screen into the project sandbox and return the file path.',
    inputSchema: { 'type': 'object', 'properties': {}, 'required': [] },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      return guarded('screenshot', 'capture screen').then((allowed: boolean) => {
        if (!allowed) {
          return 'screenshot is awaiting approval (gate not wired yet)';
        }
        const path = ctx.projectDir() + '/build/screenshot.jpeg';
        return runHvolt(['screenshot', '-o', path], ctx.projectDir()).then((run: ToolRun) => {
          return 'screenshot code=' + run.code + ' -> ' + path + '\n' + lastLines(run.output, 5);
        });
      });
    }
  });
}

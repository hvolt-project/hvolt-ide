// The sandbox shell: commands that run inside this application's own sandbox.
//
// The device shell tool reaches the phone over the device channel, where this application's files
// are readable but not writable, so it cannot change anything the application itself owns. This
// tool covers that gap: the command interpreter lives in `libnavi.so`, dispatches every command
// with ordinary POSIX calls in this process, and therefore has the same write access the
// application has to its own files.
//
// It executes nothing. There is no fork and no exec: an unknown command is an error, not a program
// to run. That is what makes it usable under the platform's executable-memory policy, and it also
// keeps the tool's surface bounded to the file operations the interpreter implements.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { sandboxSh } from 'libnavi.so';

export function registerSandboxTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'sandbox_sh',
    description: 'Run one command inside the application\'s own sandbox (where this app\'s files '
      + 'are writable). Commands: pwd, cd, ls [-l], cat, write <path> <text>, mkdir [-p], '
      + 'rm [-r] [-f], cp, mv, touch, stat, wc, head, tail, grep [-i], find, echo. Nothing is '
      + 'executed: unknown commands are reported as errors.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'One command line, e.g. "ls -l src" or "write notes.txt hello".'
        }
      },
      'required': ['command']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const command = args['command'];
      if (command === undefined || command === null) {
        return Promise.resolve('error: command is required');
      }
      const line = command as string;
      const project = ctx.projectDir();
      const root = project.length > 0 ? project : '';
      return Promise.resolve(sandboxSh(line, root));
    }
  });
}
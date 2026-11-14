// Model-authored JavaScript, executed on this device by QuickJS.
//
// QuickJS is linked into libnavi.so as a static archive: a separate shared library would add a
// DT_NEEDED edge that the package loader resolves before the module's own symbols, and when that
// resolution fails the whole native module (and with it the page) stops evaluating. Each call gets
// a fresh runtime, a memory limit and an interrupt handler that fires once at the deadline, so a
// runaway script returns an error instead of taking the app down.

import { ToolRegistry } from '../mcp/Registry';
import { jsEval } from 'libnavi.so';

export function registerJsEvalTools(registry: ToolRegistry): void {
  registry.register({
    name: 'js_eval',
    description: 'Evaluate JavaScript on the device with QuickJS and return the result. Each call '
      + 'runs in a fresh context with no state carried over, a wall-clock deadline and a memory '
      + 'cap. The value of the last expression is returned as JSON text; syntax and runtime errors '
      + 'come back as an error instead of throwing. Use it for calculations and for checking what '
      + 'a snippet does, not for touching files (use sandbox_sh for that).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'code': {
          'type': 'string',
          'description': 'JavaScript source. The completion value is returned, e.g. "1+2" gives 3.'
        },
        'timeout_ms': {
          'type': 'number',
          'description': 'Wall-clock deadline in milliseconds (default 5000, capped at 600000).'
        },
        'memory_mb': {
          'type': 'number',
          'description': 'Heap cap in megabytes (default 64).'
        }
      },
      'required': ['code']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const code = args['code'];
      if (code === undefined || code === null) {
        return Promise.resolve('error: code is required');
      }
      const timeoutArg = args['timeout_ms'];
      const memoryArg = args['memory_mb'];
      const timeoutMs: number = timeoutArg === undefined || timeoutArg === null
        ? 5000 : Math.round(timeoutArg as number);
      const memoryMb: number = memoryArg === undefined || memoryArg === null
        ? 64 : Math.round(memoryArg as number);
      return Promise.resolve(jsEval(code as string, timeoutMs, memoryMb));
    }
  });
}

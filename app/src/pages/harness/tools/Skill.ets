// Loading a skill's full instructions.
//
// The catalog the model reads carries one line per skill; acting on it requires the body. Two
// calls: no argument lists what exists, a name returns that skill. Free because it is a file read —
// there is no model call behind it, which is what keeps the catalog affordable.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

export function registerSkillTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'skill',
    description: 'Load a skill: a reusable set of task-specific instructions shipped with the ' +
      'app or written into the sandbox. Call with no argument to list what is available; call ' +
      'with a name to read its full text. Read a skill before following it — the catalog carries ' +
      'only summaries.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': { 'type': 'string', 'description': 'Exact skill name from the catalog.' }
      },
      'required': []
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const load = ctx.skill;
      if (load === undefined) {
        throw new Error('skills are not available');
      }
      const raw = args['name'];
      const name = raw === undefined ? '' : (raw as string).trim();
      return await load(name);
    }
  });
}

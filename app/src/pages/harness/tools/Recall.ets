// Reading the conversation log back.
//
// A compiled checkpoint replaces text with `(seq N)`. Without a way to resolve those pointers the
// compaction would be lossy: the model could see that something happened at seq 12 and never learn
// what. This tool is that way — it returns what was actually written, not the compiled view.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['recall'];


export function registerRecallTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'recall',
    description: 'Read the conversation log. Pass `seq` to get the original messages at an id or ' +
      'an id span (e.g. "12" or "3-7") — this is how the (seq N) pointers in a compacted context ' +
      'are resolved. Pass `query` to find which ids mention a phrase.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'seq': { 'type': 'string', 'description': 'An id ("12") or an inclusive span ("3-7").' },
        'query': { 'type': 'string', 'description': 'Phrase to search for in message bodies.' },
        'limit': { 'type': 'number', 'description': 'Maximum hits for a search. Default 5.' }
      },
      'required': []
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const run = ctx.recall;
      if (run === undefined) {
        throw new Error('the conversation log is not available');
      }
      const seq = args['seq'];
      const query = args['query'];
      let limit = 0;
      const rawLimit = args['limit'];
      if (rawLimit !== undefined && rawLimit !== null) {
        limit = rawLimit as number;
      }
      return run(seq === undefined ? '' : seq as string, query === undefined ? '' : query as string, limit);
    }
  });
}

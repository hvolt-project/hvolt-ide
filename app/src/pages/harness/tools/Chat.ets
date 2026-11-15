// Driving the in-IDE conversation from the endpoint.
//
// The point is not to build a second client: it is that the endpoint and the chat page reach the
// same session, so a turn started here is the same turn the page would start — same model, same
// tools, same approval gate, same history file.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['chat'];


const MAX_REPLY_CHARS: number = 4000;

export function registerChatTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'chat',
    description: 'Send a message to the in-IDE assistant and return its reply. Uses the ' +
      'configured model and the same conversation the chat page shows.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': { 'type': 'string', 'description': 'What to say.' }
      },
      'required': ['text']
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const send = ctx.chatSend;
      if (send === undefined) {
        throw new Error('chat is not available yet');
      }
      const text = (args['text'] as string).trim();
      if (text.length === 0) {
        throw new Error('text must not be empty');
      }
      const reply = await send(text);
      if (reply.length > MAX_REPLY_CHARS) {
        let end = Math.min(MAX_REPLY_CHARS, reply.length);
        const code = end > 0 ? reply.charCodeAt(end - 1) : 0;
        if (code >= 0xD800 && code <= 0xDBFF) {
          end -= 1;
        }
        return reply.substring(0, end) + '\n…(truncated)';
      }
      return reply.length === 0 ? '(no text; see tool lines)' : reply;
    }
  });
}

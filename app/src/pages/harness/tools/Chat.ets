// Driving the in-IDE conversation from the endpoint.
//
// The point is not to build a second client: it is that the endpoint and the chat page reach the
// same session, so a turn started here is the same turn the page would start — same model, same
// tools, same approval gate, same history file.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

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
        return reply.substring(0, MAX_REPLY_CHARS) + '\n…(truncated)';
      }
      return reply.length === 0 ? '(no text; see tool lines)' : reply;
    }
  });
}

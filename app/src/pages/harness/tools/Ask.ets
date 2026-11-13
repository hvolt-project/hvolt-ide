// Asking the person a question from inside a turn.
//
// One call may carry several questions; each has an id, and the answers come back on those ids so
// the model can tell which answer belongs to which decision. An option is a label plus the reason
// to pick it — a bare label forces the person to ask "what does that mean" before answering.
//
// The model stops here until an answer arrives: the promise this tool awaits is resolved by the
// answer panel, so one turn can ask, read the reply, and carry on with it. Cancelling resolves the
// same promise with a statement that the person declined, which is what keeps a refusal from
// becoming a retry loop.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { AskOption, AskQuestion } from '../../model/Ask';

export function registerAskTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'ask_user_question',
    description: 'Ask the person one or more questions and wait for the answers. Use it when a ' +
      'decision cannot be inferred from the project — a name, a choice between alternatives, or ' +
      'permission for something irreversible. Each question needs an id unique within the call, ' +
      'and the answers come back on those ids. Put the recommended option first and end its label ' +
      'with "(Recommended)". Give every option a description saying what choosing it costs or ' +
      'buys. The person can always answer in their own words through "custom". A reply of ' +
      '{"pending":true} means nobody answered in time; do not treat it as approval.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'questions': {
          'type': 'array',
          'description': 'One entry per question; answered in order.',
          'items': {
            'type': 'object',
            'properties': {
              'id': { 'type': 'string', 'description': 'Unique within this call.' },
              'question': { 'type': 'string', 'description': 'The question, one or two sentences.' },
              'header': { 'type': 'string', 'description': 'Short label for the panel.' },
              'multi_select': {
                'type': 'boolean',
                'description': 'Let several options be chosen; the answer lists them all.'
              },
              'options': {
                'type': 'array',
                'description': 'Enumerated choices; omit to ask for free text only.',
                'items': {
                  'type': 'object',
                  'properties': {
                    'label': { 'type': 'string' },
                    'description': { 'type': 'string' }
                  },
                  'required': ['label']
                }
              }
            },
            'required': ['id', 'question']
          }
        }
        ,
        'timeout': {
          'type': 'number',
          'description': 'Seconds to wait before handing control back. Omit to wait for an ' +
            'answer. A reply of {"pending":true} is not an approval.'
        }
      },
      'required': ['questions']
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const ask = ctx.ask;
      if (ask === undefined) {
        throw new Error('asking is not available');
      }
      const raw = args['questions'];
      if (raw === undefined || raw === null) {
        throw new Error('questions must not be empty');
      }
      const questions: AskQuestion[] = [];
      const seen: string[] = [];
      for (const entry of raw as Object[]) {
        const row = entry as Record<string, Object>;
        const id = row['id'] === undefined ? '' : (row['id'] as string).trim();
        const text = row['question'] === undefined ? '' : (row['question'] as string).trim();
        if (id.length === 0 || text.length === 0) {
          throw new Error('every question needs an id and a question');
        }
        if (seen.indexOf(id) >= 0) {
          throw new Error('duplicate question id: ' + id);
        }
        seen.push(id);
        const options: AskOption[] = [];
        const rawOptions = row['options'];
        if (rawOptions !== undefined && rawOptions !== null) {
          for (const rawOption of rawOptions as Object[]) {
            const option = rawOption as Record<string, Object>;
            const label = option['label'] === undefined ? '' : (option['label'] as string).trim();
            if (label.length === 0) {
              continue;
            }
            const description = option['description'] === undefined ? ''
              : (option['description'] as string).trim();
            options.push({ label: label, description: description });
          }
        }
        const header = row['header'] === undefined ? '' : (row['header'] as string);
        const multi = row['multi_select'] !== undefined && row['multi_select'] !== null &&
          row['multi_select'] as boolean;
        questions.push({
          id: id, question: text, header: header, options: options, multiSelect: multi
        });
      }
      if (questions.length === 0) {
        throw new Error('questions must not be empty');
      }
      const rawTimeout = args['timeout'];
      const timeoutSec = rawTimeout === undefined || rawTimeout === null ? 0
        : Math.max(0, Math.round(rawTimeout as number));
      return await ask(questions, timeoutSec);
    }
  });
}

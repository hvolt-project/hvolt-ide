// The plan the model is following, visible and durable.
//
// A long change has several steps, and a turn can end in the middle of them. Without a place to
// write them down, the next turn starts by re-reading the code to discover what was already done.
// The list is stored as JSON in the sandbox so it survives a restart, and rewriting it is how a
// step moves from pending to done.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

interface TodoItem {
  content: string;
  status: string;
}

const MAX_ITEMS = 40;

function todoPath(): string {
  return getContext().filesDir + '/todo.json';
}

function load(): TodoItem[] {
  try {
    const path = todoPath();
    if (!fs.accessSync(path)) {
      return [];
    }
    const text = fs.readTextSync(path);
    const parsed = JSON.parse(text) as Record<string, Object>;
    const raw = parsed['items'];
    const items: TodoItem[] = [];
    if (raw === undefined || raw === null) {
      return items;
    }
    for (const entry of raw as Object[]) {
      const row = entry as Record<string, Object>;
      const content = row['content'] === undefined ? '' : row['content'] as string;
      const status = row['status'] === undefined ? 'pending' : row['status'] as string;
      if (content.length > 0) {
        items.push({ content: content, status: status });
      }
    }
    return items;
  } catch (e) {
    return [];
  }
}

function save(items: TodoItem[]): void {
  try {
    const body: Record<string, Object> = { 'items': items };
    const file = fs.openSync(todoPath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE |
      fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(body));
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
  }
}

function render(items: TodoItem[]): string {
  if (items.length === 0) {
    return '待办为空';
  }
  const lines: string[] = [];
  for (const item of items) {
    const mark = item.status === 'completed' ? '[x]' : item.status === 'in_progress' ? '[>]' : '[ ]';
    lines.push(mark + ' ' + item.content);
  }
  return lines.join('\n');
}

export function registerTodoTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'todo_write',
    description: 'Replace the task list for the current work. One entry per step, each with a '
      + 'content line and a status of pending, in_progress or completed. Send the whole list every '
      + 'time; an omitted step is a dropped step. Use it for any change that needs more than two '
      + 'steps so progress survives an interruption.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'content': { 'type': 'string' },
              'status': { 'type': 'string', 'enum': ['pending', 'in_progress', 'completed'] }
            },
            'required': ['content', 'status']
          }
        }
      },
      'required': ['items']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const raw = args['items'];
      const items: TodoItem[] = [];
      if (raw !== undefined && raw !== null) {
        for (const entry of raw as Object[]) {
          const row = entry as Record<string, Object>;
          const content = row['content'] === undefined ? '' : (row['content'] as string).trim();
          const status = row['status'] === undefined ? 'pending' : row['status'] as string;
          if (content.length === 0) {
            continue;
          }
          if (items.length >= MAX_ITEMS) {
            break;
          }
          items.push({ content: content, status: status });
        }
      }
      save(items);
      return Promise.resolve(render(items));
    }
  });

  registry.register({
    name: 'todo_read',
    description: 'Read the task list as it stands.',
    inputSchema: { 'type': 'object', 'properties': {}, 'required': [] },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      return Promise.resolve(render(load()));
    }
  });
}
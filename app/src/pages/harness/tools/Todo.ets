// The plan the model is following, visible and durable.
//
// A long change has several steps, and a turn can end in the middle of them. Without a place to
// write them down, the next turn starts by re-reading the code to discover what was already done.
// The list is stored as JSON in the sandbox so it survives a restart, and rewriting it is how a
// step moves from pending to done.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['todo_write', 'todo_read'];


interface TodoItem {
  content: string;
  status: string;
}

const MAX_ITEMS = 40;

/** 界面渲染用的一行。工具写、界面读，两边看同一份文件。 */
export interface TodoViewItem {
  content: string;
  status: string;
}

/** 当前清单，给界面的只读入口。读失败时返回空表：面板是装饰，不该打断对话。 */
export function readTodos(): TodoViewItem[] {
  return load();
}

/**
 * 清空清单。
 *
 * 重置对话时必须一起清：计划描述的是「这一段对话要做到哪」，对话清了它还在，
 * 顶上就挂着一份不存在的进度，读者会以为还有活没干。
 */
export function clearTodos(): void {
  try {
    const path = todoPath();
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (e) {
    // 删不掉就退回空表：清空失败不该让重置本身失败。
  }
}

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
    description: 'Change the task list for the current work. One entry per step. '
      + 'action=write replaces the whole list (send every item, an omitted one is dropped); '
      + 'action=add appends one item; action=update changes the status (or content) of the item at '
      + '1-based `index`; action=remove deletes it; action=clear empties the list. '
      + 'Prefer add/update: rewriting the whole list means every pass has to carry items it did not '
      + 'touch, and one forgotten item disappears without a word. Use it for any change that takes '
      + 'more than two steps, so progress survives an interruption.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['write', 'add', 'update', 'remove', 'clear'],
          'description': 'What to do with the list.'
        },
        'items': {
          'type': 'array',
          'description': 'write only: the complete list, in order.',
          'items': {
            'type': 'object',
            'properties': {
              'content': { 'type': 'string' },
              'status': { 'type': 'string', 'enum': ['pending', 'in_progress', 'completed'] }
            },
            'required': ['content', 'status']
          }
        },
        'index': {
          'type': 'number',
          'description': 'update / remove: 1-based position in the list as todo_read prints it.'
        },
        'content': {
          'type': 'string',
          'description': 'add / update: the step, one line.'
        },
        'status': {
          'type': 'string',
          'enum': ['pending', 'in_progress', 'completed'],
          'description': 'add / update: new status. Defaults to pending for add.'
        }
      },
      'required': ['action']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const action = args['action'] === undefined ? '' : (args['action'] as string);
      const current = load();
      if (action === 'write') {
        const items: TodoItem[] = [];
        const raw = args['items'];
        if (raw !== undefined && raw !== null) {
          for (const entry of raw as Object[]) {
            const row = entry as Record<string, Object>;
            const content = row['content'] === undefined ? '' : (row['content'] as string).trim();
            const status = row['status'] === undefined ? 'pending' : row['status'] as string;
            if (content.length === 0 || items.length >= MAX_ITEMS) {
              continue;
            }
            items.push({ content: content, status: status });
          }
        }
        save(items);
        return Promise.resolve('已替换整张表。\n' + render(items));
      }
      if (action === 'clear') {
        save([]);
        return Promise.resolve('已清空。\n' + render([]));
      }
      const index = args['index'] === undefined ? 0 : Math.round(args['index'] as number);
      if (action === 'add') {
        const content = args['content'] === undefined ? '' : (args['content'] as string).trim();
        if (content.length === 0) {
          return Promise.resolve('error: add needs content');
        }
        if (current.length >= MAX_ITEMS) {
          return Promise.resolve('error: list is full (' + String(MAX_ITEMS) + ' items)');
        }
        const status = args['status'] === undefined ? 'pending' : args['status'] as string;
        current.push({ content: content, status: status });
        save(current);
        return Promise.resolve('已添加第 ' + String(current.length) + ' 条。\n' + render(current));
      }
      if (action === 'update' || action === 'remove') {
        if (index < 1 || index > current.length) {
          return Promise.resolve('error: index must be 1-' + String(current.length)
            + '; todo_read shows the numbering');
        }
        const at = index - 1;
        if (action === 'remove') {
          const gone = current[at].content;
          current.splice(at, 1);
          save(current);
          return Promise.resolve('已删除「' + gone + '」。\n' + render(current));
        }
        if (args['content'] !== undefined && args['content'] !== null) {
          const text = (args['content'] as string).trim();
          if (text.length > 0) {
            current[at].content = text;
          }
        }
        if (args['status'] !== undefined && args['status'] !== null) {
          current[at].status = args['status'] as string;
        }
        save(current);
        return Promise.resolve('已更新第 ' + String(index) + ' 条。\n' + render(current));
      }
      return Promise.resolve('error: unknown action `' + action + '`');
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
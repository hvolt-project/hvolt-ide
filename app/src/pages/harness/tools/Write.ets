// Whole-file write. Reports whether the content actually changed, so the caller can decide
// whether the editor needs to be synchronised.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { safePath } from '../fs/Walk';
import { FileContext, requireProject } from './Files';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['write'];


/** FNV-1a over UTF-16 code units: enough to tell "same bytes" from "different bytes". */
export function contentHash(text: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16);
}

export function registerWriteTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'write',
    description: 'Replace the whole content of one file in the open project.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': { 'type': 'string', 'description': 'Path relative to the project root.' },
        'content': { 'type': 'string', 'description': 'Full new content.' }
      },
      'required': ['path', 'content']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const path = args['path'] as string;
      const content = args['content'] as string;
      const full = safePath(root, path);

      let before = '';
      try {
        before = fs.readTextSync(full);
      } catch (e) {
        before = '';
      }
      if (before === content) {
        return Promise.resolve(path + ': unchanged (' + contentHash(content) + ')');
      }
      const file = fs.openSync(full, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      return Promise.resolve(path + ': written ' + content.length + ' chars (' + contentHash(content) + ')');
    }
  });
}

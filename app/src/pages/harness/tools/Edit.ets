// Literal replacement inside one file. Uniqueness is enforced rather than guessed: a needle that
// appears twice is a mistake at the call site, and picking either occurrence silently would edit
// code the caller never saw.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { safePath } from '../fs/Walk';
import { FileContext, requireProject } from './Files';

/** Number of non-overlapping occurrences of `needle` in `text`. */
export function occurrences(text: string, needle: string): number {
  if (needle.length === 0) {
    return 0;
  }
  let count = 0;
  let at = text.indexOf(needle);
  while (at >= 0) {
    count++;
    at = text.indexOf(needle, at + needle.length);
  }
  return count;
}

export function registerEditTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'edit',
    description: 'Replace one unique occurrence of old_string with new_string in a project file.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': { 'type': 'string', 'description': 'Path relative to the project root.' },
        'old_string': { 'type': 'string', 'description': 'Text to replace; must appear exactly once.' },
        'new_string': { 'type': 'string', 'description': 'Replacement text.' }
      },
      'required': ['path', 'old_string', 'new_string']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const path = args['path'] as string;
      const oldText = args['old_string'] as string;
      const newText = args['new_string'] as string;
      if (oldText.length === 0) {
        throw new Error('old_string must not be empty');
      }
      const full = safePath(root, path);
      let before = '';
      try {
        before = fs.readTextSync(full);
      } catch (e) {
        throw new Error('cannot read ' + path);
      }
      const hits = occurrences(before, oldText);
      if (hits === 0) {
        throw new Error('old_string not found in ' + path);
      }
      if (hits > 1) {
        throw new Error('old_string appears ' + hits + ' times in ' + path + '; include more context');
      }
      const after = before.replace(oldText, newText);
      const file = fs.openSync(full, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, after);
      } finally {
        fs.closeSync(file);
      }
      return Promise.resolve(path + ': replaced 1 occurrence');
    }
  });
}

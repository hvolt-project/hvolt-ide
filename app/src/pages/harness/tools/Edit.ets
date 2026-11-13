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


/**
 * Several replacements in one call, applied only if every one of them is valid.
 *
 * The single-replacement tool forces one call per edit, and a file that needs four edits costs four
 * round trips. Validating the whole set first is what keeps a half-applied patch from existing: if
 * one old_string is missing, nothing is written at all.
 */
function registerPatchTool(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'apply_patch',
    description: 'Apply several exact-text replacements in one call. Every edit names a file, an '
      + 'old_string that must appear exactly once in it, and its new_string. All edits are checked '
      + 'before any file is written: if one old_string does not match exactly once, nothing changes.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'edits': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'path': { 'type': 'string', 'description': 'Path relative to the project root.' },
              'old_string': { 'type': 'string' },
              'new_string': { 'type': 'string' }
            },
            'required': ['path', 'old_string', 'new_string']
          }
        }
      },
      'required': ['edits']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const raw = args['edits'];
      if (raw === undefined || raw === null) {
        throw new Error('edits must not be empty');
      }
      const pending: Map<string, string> = new Map<string, string>();
      const report: string[] = [];
      let index = 0;
      for (const entry of raw as Object[]) {
        index += 1;
        const row = entry as Record<string, Object>;
        const path = (row['path'] as string).trim();
        const oldText = row['old_string'] as string;
        const newText = row['new_string'] as string;
        if (path.length === 0) {
          throw new Error('edit ' + index + ': path is required');
        }
        if (oldText.length === 0) {
          throw new Error('edit ' + index + ': old_string must not be empty');
        }
        const full = safePath(root, path);
        let current = pending.get(full);
        if (current === undefined) {
          try {
            current = fs.readTextSync(full);
          } catch (e) {
            throw new Error('edit ' + index + ': cannot read ' + path);
          }
        }
        let hits = 0;
        let at = current.indexOf(oldText);
        while (at >= 0) {
          hits += 1;
          at = current.indexOf(oldText, at + oldText.length);
        }
        if (hits === 0) {
          throw new Error('edit ' + index + ': old_string not found in ' + path);
        }
        if (hits > 1) {
          throw new Error('edit ' + index + ': old_string appears ' + hits + ' times in ' + path);
        }
        const next = current.replace(oldText, newText);
        pending.set(full, next);
        report.push(path + ': replaced 1 occurrence');
      }
      pending.forEach((text: string, full: string) => {
        const file = fs.openSync(full, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, text);
        } finally {
          fs.closeSync(file);
        }
      });
      return Promise.resolve(report.join('\n'));
    }
  });
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
  registerPatchTool(registry, ctx);
}

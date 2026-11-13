// File and search tools. Each one is a pure function over the project directory: it resolves
// through Walk.safePath, does its work, and returns text for the model. No UI, no device calls.

import fs from '@ohos.file.fs';
import { ToolRegistry } from '../mcp/Registry';
import { globMatcher, relativeTo, safePath, walkFiles } from '../fs/Walk';
import { AskQuestion } from '../../model/Ask';
import { listProjects, projectDir } from '../../model/Project';

function projectLabel(dir: string): string {
  const cut = dir.lastIndexOf('/');
  return cut >= 0 ? dir.substring(cut + 1) : dir;
}

export interface FileContext {
  /** Absolute sandbox path of the open project; '' when none is open. */
  projectDir: () => string;
  /** Runs one turn against the in-IDE conversation, using whatever the settings configure. */
  chatSend?: (text: string) => Promise<string>;
  /** Resolves a conversation-log pointer: `seq` (an id or span) or `query`, whichever is non-empty. */
  recall?: (seq: string, query: string, limit: number) => Promise<string>;
  /** Puts a question in front of the person and resolves with their answer. */
  ask?: (questions: AskQuestion[], timeoutSec: number) => Promise<string>;
  /** Loads a skill by name; an empty name lists what is available. */
  skill?: (name: string) => Promise<string>;
  /** Directory of the IDE's own unpacked source; '' until it has been unpacked. */
  selfSourceDir?: () => string;
}

const MAX_READ_BYTES: number = 200 * 1024;
const MAX_GREP_HITS: number = 200;

export function requireProject(ctx: FileContext): string {
  const root = ctx.projectDir();
  if (root.length === 0) {
    throw new Error('no project is open');
  }
  return root;
}

function readWhole(root: string, rel: string): string {
  const full = safePath(root, rel);
  let size = 0;
  try {
    size = fs.statSync(full).size;
  } catch (e) {
    throw new Error('cannot stat ' + rel);
  }
  if (size > MAX_READ_BYTES) {
    throw new Error('file is ' + size + ' bytes, over the ' + MAX_READ_BYTES + ' limit: ' + rel);
  }
  return fs.readTextSync(full);
}

function numberLines(text: string): string {
  const lines: string[] = text.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    out.push((i + 1) + ' ' + lines[i]);
  }
  return out.join('\n');
}

export function registerFileTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'read',
    description: 'Read one text file from the open project, returned with line numbers.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': { 'type': 'string', 'description': 'Path relative to the project root.' }
      },
      'required': ['path']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const root = requireProject(ctx);
      const path = args['path'] as string;
      const text = readWhole(root, path);
      return Promise.resolve(numberLines(text));
    }
  });

  registry.register({
    name: 'glob',
    description: 'List files in the open project matching a glob (** crosses directories).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': { 'type': 'string', 'description': 'Glob such as **/*.ets.' }
      },
      'required': ['pattern']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const scope = args['scope'] === undefined ? 'project' : args['scope'] as string;
      const roots: string[] = [];
      if (scope === 'all') {
        for (const name of listProjects()) {
          roots.push(projectDir(name));
        }
      } else {
        roots.push(requireProject(ctx));
      }
      const root = roots.length > 0 ? roots[0] : requireProject(ctx);
      const pattern = args['pattern'] as string;
      const matcher = globMatcher(pattern);
      const hits: string[] = [];
      for (const rel of walkFiles(root)) {
        if (matcher.test(rel)) {
          hits.push(rel);
        }
      }
      return Promise.resolve(hits.length === 0 ? 'no matches' : hits.join('\n'));
    }
  });

  registry.register({
    name: 'grep',
    description: 'Search file contents by regular expression and report file:line matches.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': { 'type': 'string', 'description': 'Regular expression to match.' },
        'include': { 'type': 'string', 'description': 'Optional glob limiting which files are searched.' },
        'scope': {
          'type': 'string',
          'enum': ['project', 'all'],
          'description': 'project (default) searches the open project; all searches every project in the sandbox.'
        }
      },
      'required': ['pattern']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const scope = args['scope'] === undefined ? 'project' : args['scope'] as string;
      const roots: string[] = [];
      if (scope === 'all') {
        for (const name of listProjects()) {
          roots.push(projectDir(name));
        }
      } else {
        roots.push(requireProject(ctx));
      }
      const root = roots.length > 0 ? roots[0] : requireProject(ctx);
      const pattern = args['pattern'] as string;
      const include = args['include'] === undefined ? '**/*' : args['include'] as string;
      const matcher = globMatcher(include);
      const needle = new RegExp(pattern);
      const hits: string[] = [];
      for (const scanRoot of roots) {
        const label = scope === 'all' ? projectLabel(scanRoot) + '/' : '';
        for (const rel of walkFiles(scanRoot)) {
          if (!matcher.test(rel)) {
            continue;
          }
          let text = '';
          try {
            text = readWhole(scanRoot, rel);
          } catch (e) {
            continue;
          }
          const lines: string[] = text.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (needle.test(lines[i])) {
              // With several roots in play the project name has to be part of the hit, or two
              // matches in different projects read as one line reported twice.
              hits.push(label + rel + ':' + (i + 1) + ': ' + lines[i].trim());
              if (hits.length >= MAX_GREP_HITS) {
                return Promise.resolve(hits.join('\n'));
              }
            }
          }
        }
      }
      return Promise.resolve(hits.length === 0 ? 'no matches' : hits.join('\n'));
    }
  });
}

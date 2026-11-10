// Shared directory walk for the file tools. read/glob/grep all resolve paths through here, so
// the sandbox boundary and the traversal order are defined once.

import fs from '@ohos.file.fs';

/** Raised for any path that escapes the project root or cannot be resolved. */
export class PathError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PathError';
  }
}

/** Absolute path for `rel` under `root`, rejecting anything that climbs out of the root. */
export function safePath(root: string, rel: string): string {
  const cleaned: string = rel.replace(/\\/g, '/');
  const parts: string[] = cleaned.split('/');
  const kept: string[] = [];
  for (const part of parts) {
    if (part.length === 0 || part === '.') {
      continue;
    }
    if (part === '..') {
      if (kept.length === 0) {
        throw new PathError('path escapes the project root: ' + rel);
      }
      kept.pop();
      continue;
    }
    kept.push(part);
  }
  if (kept.length === 0) {
    return root;
  }
  return root + '/' + kept.join('/');
}

/** POSIX-style path relative to `root`, or '' when `full` is the root itself. */
export function relativeTo(root: string, full: string): string {
  if (full === root) {
    return '';
  }
  const cut = full.indexOf(root);
  if (cut !== 0) {
    return full;
  }
  const rest = full.substring(root.length);
  return rest.startsWith('/') ? rest.substring(1) : rest;
}

/** Every file under `root`, as sorted POSIX-style relative paths. */
export function walkFiles(root: string): string[] {
  const out: string[] = [];
  visit(root, '', out);
  out.sort();
  return out;
}

function visit(dir: string, prefix: string, out: string[]): void {
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    return;
  }
  names.sort();
  for (const name of names) {
    const full: string = dir + '/' + name;
    const rel: string = prefix.length === 0 ? name : prefix + '/' + name;
    let isDir: boolean = false;
    try {
      isDir = fs.statSync(full).isDirectory();
    } catch (e) {
      continue;
    }
    if (isDir) {
      visit(full, rel, out);
    } else {
      out.push(rel);
    }
  }
}

/** Glob → regexp: `**` crosses directories, `*` and `?` stay within one segment. */
export function globMatcher(pattern: string): RegExp {
  let source = '^';
  let i = 0;
  while (i < pattern.length) {
    const c = pattern.charAt(i);
    if (c === '*' && pattern.charAt(i + 1) === '*') {
      source += '.*';
      i += 2;
      continue;
    }
    if (c === '*') {
      source += '[^/]*';
      i += 1;
      continue;
    }
    if (c === '?') {
      source += '[^/]';
      i += 1;
      continue;
    }
    if ('.+^$()[]{}|\\'.indexOf(c) >= 0) {
      source += '\\' + c;
      i += 1;
      continue;
    }
    source += c;
    i += 1;
  }
  source += '$';
  return new RegExp(source);
}

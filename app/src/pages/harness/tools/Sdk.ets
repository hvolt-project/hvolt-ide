// SDK lookup.
//
// The full .d.ts set is 21 MB and does not belong in the package, but an agent writing ArkTS
// without API signatures guesses. So the package carries a symbol index instead: kind, name,
// file:line, one-line summary, signature — 7551 symbols in about a megabyte. It answers "what is
// this called and how is it declared", which is what a wrong guess gets wrong.

import util from '@ohos.util';
import { ToolRegistry } from '../mcp/Registry';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['sdk_search', 'sdk_read'];


// 实际布局是 rawfile/sdk/sdk/：外层 sdk/ 是打包入口，里层才是 SDK 视图本身（api/ 与
// index.tsv 都在里面）。少写一层时两个工具都读不到文件，表现为「sdk_search 坏了」。
const INDEX_FILE: string = 'sdk/sdk/index.tsv';
const API_DIR: string = 'sdk/sdk/api/';
const MAX_LINES: number = 120;
const DEFAULT_LIMIT: number = 10;
const MAX_LIMIT: number = 40;

interface SdkRow {
  kind: string;
  symbol: string;
  where: string;
  summary: string;
  signature: string;
}

let rows: SdkRow[] | null = null;

async function loadIndex(): Promise<SdkRow[]> {
  if (rows !== null) {
    return rows;
  }
  const rm = getContext().resourceManager;
  const bytes: Uint8Array = await rm.getRawFileContent(INDEX_FILE);
  const decoder = util.TextDecoder.create('utf-8');
  const text = decoder.decodeToString(bytes);
  const parsed: SdkRow[] = [];
  for (const line of text.split('\n')) {
    if (line.length === 0) {
      continue;
    }
    const parts: string[] = line.split('\t');
    if (parts.length < 5) {
      continue;
    }
    parsed.push({
      kind: parts[0], symbol: parts[1], where: parts[2], summary: parts[3], signature: parts[4]
    });
  }
  rows = parsed;
  return parsed;
}

function format(row: SdkRow): string {
  const head = row.kind + ' ' + row.symbol + '  (' + row.where + ')';
  const tail = row.summary.length > 0 ? '\n    ' + row.summary : '';
  return head + tail + '\n    ' + row.signature;
}

export function registerSdkTools(registry: ToolRegistry): void {
  registry.register({
    name: 'sdk_search',
    description: 'Search HarmonyOS SDK symbols by name or signature text. Returns declaration ' +
      'kind, file:line, a one-line summary and the declaration itself.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': { 'type': 'string', 'description': 'Symbol name or text such as watcher or webview.' },
        'limit': { 'type': 'number', 'description': 'Max results (default 10, max 40).' }
      },
      'required': ['query']
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const query = (args['query'] as string).trim();
      if (query.length === 0) {
        throw new Error('query must not be empty');
      }
      const wanted = args['limit'] === undefined ? DEFAULT_LIMIT : args['limit'] as number;
      const limit = wanted <= 0 ? DEFAULT_LIMIT : (wanted > MAX_LIMIT ? MAX_LIMIT : wanted);
      const all = await loadIndex();
      const needle = query.toLowerCase();
      const exact: SdkRow[] = [];
      const partial: SdkRow[] = [];
      for (const row of all) {
        const name = row.symbol.toLowerCase();
        if (name === needle) {
          exact.push(row);
        } else if (name.indexOf(needle) >= 0) {
          partial.push(row);
        } else if (row.signature.toLowerCase().indexOf(needle) >= 0) {
          partial.push(row);
        }
        if (exact.length + partial.length > 400) {
          break;
        }
      }
      const chosen = exact.concat(partial).slice(0, limit);
      if (chosen.length === 0) {
        return 'no SDK symbol matches "' + query + '"';
      }
      const out: string[] = [];
      for (const row of chosen) {
        out.push(format(row));
      }
      return out.join('\n\n');
    }
  });

  registry.register({
    name: 'sdk_read',
    description: 'Read a slice of an SDK declaration file around a line, for full comments and ' +
      'neighbouring declarations. Use the file:line that sdk_search returned.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'file': { 'type': 'string', 'description': 'Declaration file path, as reported by sdk_search.' },
        'line': { 'type': 'number', 'description': 'Line to centre the slice on.' },
        'lines': { 'type': 'number', 'description': 'How many lines to return (default 40, max 120).' }
      },
      'required': ['file', 'line']
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const file = (args['file'] as string).trim();
      if (file.length === 0 || file.indexOf('..') >= 0) {
        throw new Error('file must name a declaration file inside the SDK');
      }
      const centre = args['line'] as number;
      const wanted = args['lines'] === undefined ? 40 : args['lines'] as number;
      const span = wanted <= 0 ? 40 : (wanted > MAX_LINES ? MAX_LINES : wanted);
      const rm = getContext().resourceManager;
      let bytes: Uint8Array;
      try {
        bytes = await rm.getRawFileContent(API_DIR + file);
      } catch (e) {
        throw new Error('no such declaration file: ' + file);
      }
      const decoder = util.TextDecoder.create('utf-8');
      const all: string[] = decoder.decodeToString(bytes).split('\n');
      const half = Math.floor(span / 2);
      let start = centre - half;
      if (start < 1) {
        start = 1;
      }
      let end = start + span - 1;
      if (end > all.length) {
        end = all.length;
        start = end - span + 1 < 1 ? 1 : end - span + 1;
      }
      const out: string[] = [];
      out.push(file + ':' + start + '-' + end + ' of ' + all.length);
      for (let n = start; n <= end; n++) {
        out.push(n + '\t' + all[n - 1]);
      }
      return out.join('\n');
    }
  });
}

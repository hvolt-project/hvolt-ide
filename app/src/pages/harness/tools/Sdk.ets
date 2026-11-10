// SDK lookup.
//
// The full .d.ts set is 21 MB and does not belong in the package, but an agent writing ArkTS
// without API signatures guesses. So the package carries a symbol index instead: kind, name,
// file:line, one-line summary, signature — 7551 symbols in about a megabyte. It answers "what is
// this called and how is it declared", which is what a wrong guess gets wrong.

import util from '@ohos.util';
import { ToolRegistry } from '../mcp/Registry';

const INDEX_FILE: string = 'sdk/index.tsv';
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
}

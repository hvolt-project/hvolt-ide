// Reading the outside world.
//
// The device ships an HTTP client, so fetching a page is a request away; searching needs a search
// endpoint, which this application does not ship. Both tools say what they did and what they could
// not do rather than pretending an answer exists: a search with no endpoint configured reports the
// missing configuration, and the model can fall back to fetching a known URL.

import http from '@ohos.net.http';
import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { readPref } from '../../model/Prefs';

/** Text a single fetch may return. Larger pages are cut and marked, never silently truncated. */
const MAX_BODY = 60000;
const TIMEOUT_MS = 20000;

function fetchText(url: string, limit: number): Promise<string> {
  return new Promise<string>((resolve) => {
    const request = http.createHttp();
    request.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      header: {
        'User-Agent': 'hvolt-ide/1.0',
        'Accept': 'text/html,application/json,text/plain,*/*'
      }
    }).then((response: http.HttpResponse) => {
      request.destroy();
      if (response.responseCode < 200 || response.responseCode >= 300) {
        resolve('error: HTTP ' + response.responseCode + ' for ' + url);
        return;
      }
      const body = typeof response.result === 'string' ? response.result as string
        : JSON.stringify(response.result);
      resolve(body.length > limit ? body.substring(0, limit) +
        '\n…（正文共 ' + body.length + ' 字符，已截断）' : body);
    }).catch((e: Error) => {
      request.destroy();
      resolve('error: ' + e.message);
    });
  });
}

export function registerWebTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'web_fetch',
    description: 'Fetch one URL and return its body as text (HTML is returned as written). Use it '
      + 'when a specific page, document or API endpoint is known.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': { 'type': 'string', 'description': 'Absolute http(s) URL.' },
        'limit': { 'type': 'number', 'description': 'Max characters to return; default 60000.' }
      },
      'required': ['url']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const url = (args['url'] as string).trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        return Promise.resolve('error: url must start with http:// or https://');
      }
      const rawLimit = args['limit'];
      const limit = rawLimit === undefined ? MAX_BODY : rawLimit as number;
      return fetchText(url, limit > MAX_BODY ? MAX_BODY : limit);
    }
  });

  registry.register({
    name: 'web_search',
    description: 'Search the web through the endpoint configured in settings. Without a configured '
      + 'endpoint this reports the missing configuration instead of inventing results.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': { 'type': 'string', 'description': 'Search terms.' }
      },
      'required': ['query']
    },
    approval: 'none',
    handler: async (args: Record<string, Object>): Promise<string> => {
      const query = (args['query'] as string).trim();
      if (query.length === 0) {
        return 'error: query is required';
      }
      const endpoint = await readSearchEndpoint();
      if (endpoint.length === 0) {
        return '未配置检索端点：在设置里填 webSearchUrl（形如 https://host/search?q={query}），' +
          '或改用 web_fetch 直接取一个已知 URL。';
      }
      const url = endpoint.indexOf('{query}') >= 0
        ? endpoint.replace('{query}', encodeURIComponent(query))
        : endpoint + encodeURIComponent(query);
      return fetchText(url, MAX_BODY);
    }
  });
}

/** The search endpoint from preferences; '' when unset. */
async function readSearchEndpoint(): Promise<string> {
  const value = await readPref('webSearchUrl', '');
  return value.trim();
}
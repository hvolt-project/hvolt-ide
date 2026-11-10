// Listing the models an endpoint offers.
//
// The model name is not something a user should have to type from memory: endpoints advertise
// it, and a typo there fails as an opaque 404 at the first message. So the settings page asks
// the endpoint instead.

import http from '@ohos.net.http';
import { LlmConfig } from './Settings';

/**
 * The single place a stored endpoint is interpreted.
 *
 * The preference holds the base only — up to and including the version segment, e.g.
 * https://api.deepseek.com/v1. Both the chat route and the model listing are derived from it
 * here, so the two can never disagree about what the user typed.
 */
export function normalizeBase(baseUrl: string): string {
  let base = baseUrl.trim();
  const chat = '/chat/completions';
  if (base.endsWith(chat)) {
    base = base.substring(0, base.length - chat.length);
  }
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

export function chatUrl(baseUrl: string): string {
  return normalizeBase(baseUrl) + '/chat/completions';
}

export function modelsUrl(baseUrl: string): string {
  return normalizeBase(baseUrl) + '/models';
}

interface ModelRow {
  id: string;
}

export interface ModelList {
  ok: boolean;
  models: string[];
  problem: string;
}

/** Fetches the advertised model ids, newest endpoint shape first then the older one. */
export async function listModels(config: LlmConfig): Promise<ModelList> {
  if (config.baseUrl.trim().length === 0) {
    return { ok: false, models: [], problem: '先填地址' };
  }
  const request = http.createHttp();
  try {
    const response = await request.request(modelsUrl(config.baseUrl), {
      method: http.RequestMethod.GET,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + config.token
      },
      connectTimeout: 15000,
      readTimeout: 20000,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode !== 200) {
      return { ok: false, models: [], problem: 'HTTP ' + response.responseCode };
    }
    const text = response.result as string;
    const parsed = JSON.parse(text) as Record<string, Object>;
    const rows = parsed['data'] as Object[];
    const ids: string[] = [];
    if (rows !== undefined && rows !== null) {
      for (const raw of rows) {
        const id = (raw as Record<string, Object>)['id'];
        if (id !== undefined && id !== null) {
          ids.push(id as string);
        } else {
          const name = (raw as Record<string, Object>)['name'];
          if (name !== undefined && name !== null) {
            ids.push(name as string);
          }
        }
      }
    }
    ids.sort();
    if (ids.length === 0) {
      return { ok: false, models: [], problem: '端点没有返回模型' };
    }
    return { ok: true, models: ids, problem: '' };
  } catch (e) {
    return { ok: false, models: [], problem: (e as Error).message };
  } finally {
    request.destroy();
  }
}

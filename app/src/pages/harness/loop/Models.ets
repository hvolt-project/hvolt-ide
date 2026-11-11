// Listing the models an endpoint offers.
//
// The model name is not something a user should have to type from memory: endpoints advertise
// it, and a typo there fails as an opaque 404 at the first message. So the settings page asks
// the endpoint instead.

import http from '@ohos.net.http';
import { LlmConfig } from './Settings';
import { chatUrl, modelsUrl, normalizeBase } from './Urls';

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

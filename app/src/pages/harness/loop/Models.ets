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

/** 一个端点的上下文窗口，单位 token；拿不到就返回 0。
 *
 * 各家 /models 的字段名不一致：OpenRouter 用 context_length（也可能缩在 top_provider 里），
 * vLLM 用 max_model_len，Anthropic 用 context_window。按候选顺序取第一个正数。
 *
 * 拿不到时返回 0，不编默认值：一个错的窗口会让触发线落在永远到不了的地方（1000000 × 0.5），
 * 自动压缩从此形同不存在，而状态栏的百分比也在拿一个不存在的分母说话。
 */
export async function fetchContextWindow(config: LlmConfig): Promise<number> {
  if (config.baseUrl.trim().length === 0) {
    return 0;
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
      return 0;
    }
    const parsed = JSON.parse(response.result as string) as Record<string, Object>;
    const rows = parsed['data'] as Object[];
    if (rows === undefined || rows === null) {
      return 0;
    }
    let fallback: number = 0;
    for (const raw of rows) {
      const row = raw as Record<string, Object>;
      const id = row['id'];
      const tokens = windowOfRow(row);
      if (tokens <= 0) {
        continue;
      }
      if (id !== undefined && id !== null && (id as string) === config.model.trim()) {
        return tokens;
      }
      if (fallback === 0) {
        fallback = tokens;
      }
    }
    // 端点只承认一个模型时，那个数就是本次要用的窗口。
    return fallback;
  } catch (e) {
    return 0;
  } finally {
    request.destroy();
  }
}

/** 一行模型记录里的窗口数字，字段名按各家形态依次试。 */
function windowOfRow(row: Record<string, Object>): number {
  const direct = ['context_length', 'max_model_len', 'context_window', 'max_input_tokens',
    'max_context_length'];
  for (const key of direct) {
    const value = row[key];
    if (typeof value === 'number' && (value as number) > 0) {
      return value as number;
    }
  }
  const provider = row['top_provider'];
  if (provider !== undefined && provider !== null && typeof provider === 'object') {
    const nested = (provider as Record<string, Object>)['context_length'];
    if (typeof nested === 'number' && (nested as number) > 0) {
      return nested as number;
    }
  }
  return 0;
}

// Where the model endpoint comes from: a preference, never a constant. The key is stored in the
// app sandbox like every other preference; there is no default endpoint that would silently send
// code somewhere the user did not choose.

import { readPref, writePref } from '../../model/Prefs';

const KEY_BASE: string = 'llm.base';
const KEY_MODEL: string = 'llm.model';
const KEY_TOKEN: string = 'llm.key';
const KEY_EFFORT: string = 'llm.effort';
const KEY_WINDOW: string = 'llm.window';

export class LlmConfig {
  baseUrl: string = '';
  model: string = '';
  token: string = '';
  /** '' means the provider's default; low / medium / high are sent only when chosen. */
  effort: string = '';
  /** 上下文窗口（token）。0 表示未配置，由调用方回退到默认值。 */
  contextWindow: number = 0;

  ready(): boolean {
    return this.baseUrl.length > 0 && this.model.length > 0 && this.token.length > 0;
  }
}

export async function loadLlmConfig(): Promise<LlmConfig> {
  const config = new LlmConfig();
  config.baseUrl = await readPref(KEY_BASE, '');
  config.model = await readPref(KEY_MODEL, '');
  config.token = await readPref(KEY_TOKEN, '');
  config.effort = await readPref(KEY_EFFORT, '');
  const windowText: string = await readPref(KEY_WINDOW, '');
  const windowValue: number = parseInt(windowText, 10);
  config.contextWindow = Number.isNaN(windowValue) || windowValue <= 0 ? 0 : windowValue;
  return config;
}

export function saveLlmConfig(config: LlmConfig): void {
  writePref(KEY_BASE, config.baseUrl.trim());
  writePref(KEY_MODEL, config.model.trim());
  writePref(KEY_TOKEN, config.token.trim());
  writePref(KEY_EFFORT, config.effort.trim());
  writePref(KEY_WINDOW, config.contextWindow > 0 ? String(config.contextWindow) : '');
}

// Where the model endpoint comes from: a preference, never a constant. The key is stored in the
// app sandbox like every other preference; there is no default endpoint that would silently send
// code somewhere the user did not choose.

import { readPref, writePref } from '../../model/Prefs';

const KEY_BASE: string = 'llm.base';
const KEY_MODEL: string = 'llm.model';
const KEY_TOKEN: string = 'llm.key';

export class LlmConfig {
  baseUrl: string = '';
  model: string = '';
  token: string = '';

  ready(): boolean {
    return this.baseUrl.length > 0 && this.model.length > 0 && this.token.length > 0;
  }
}

export async function loadLlmConfig(): Promise<LlmConfig> {
  const config = new LlmConfig();
  config.baseUrl = await readPref(KEY_BASE, '');
  config.model = await readPref(KEY_MODEL, '');
  config.token = await readPref(KEY_TOKEN, '');
  return config;
}

export function saveLlmConfig(config: LlmConfig): void {
  writePref(KEY_BASE, config.baseUrl.trim());
  writePref(KEY_MODEL, config.model.trim());
  writePref(KEY_TOKEN, config.token.trim());
}

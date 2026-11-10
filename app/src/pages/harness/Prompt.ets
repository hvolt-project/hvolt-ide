// System prompt assembly: the shipped markdown plus what is true right now.
//
// The static file explains hvolt; the runtime block explains this session. Keeping them apart
// means the shipped text can be reviewed as documentation, and the volatile part is never stale
// in a file that looks authoritative.

import util from '@ohos.util';
import { readPref, writePref } from '../model/Prefs';

const PROMPT_FILE: string = 'harness/system.md';
const KEY_EXTRA: string = 'harness.extra';

export interface RuntimeContext {
  projectName: string;
  currentFile: string;
  deviceAddress: string;
  connected: boolean;
}

/** The shipped prompt, or '' when the file cannot be read (the loop still works, just blind). */
export async function loadPromptFile(): Promise<string> {
  try {
    const rm = getContext().resourceManager;
    const bytes: Uint8Array = await rm.getRawFileContent(PROMPT_FILE);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  } catch (e) {
    return '';
  }
}

function runtimeBlock(ctx: RuntimeContext): string {
  const lines: string[] = [];
  lines.push('## 当前状态');
  lines.push('- 工程：' + (ctx.projectName.length === 0 ? '（未打开）' : ctx.projectName));
  lines.push('- 当前文件：' + (ctx.currentFile.length === 0 ? '（无）' : ctx.currentFile));
  lines.push('- 设备：' + (ctx.connected ? '已连接 ' + ctx.deviceAddress : '未连接'));
  return lines.join('\n');
}

/** Static prompt + runtime block + whatever the user added in settings. */
export async function buildSystemPrompt(ctx: RuntimeContext): Promise<string> {
  const base = await loadPromptFile();
  const extra = await readPref(KEY_EXTRA, '');
  const parts: string[] = [];
  if (base.length > 0) {
    parts.push(base);
  }
  parts.push(runtimeBlock(ctx));
  if (extra.length > 0) {
    parts.push('## 用户附加要求\n' + extra);
  }
  return parts.join('\n\n');
}

export function saveExtraInstructions(text: string): void {
  writePref(KEY_EXTRA, text).catch(() => {
  });
}

export function loadExtraInstructions(): Promise<string> {
  return readPref(KEY_EXTRA, '');
}

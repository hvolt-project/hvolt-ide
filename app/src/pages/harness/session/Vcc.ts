// VCC 式确定性压缩：不调模型，只用原文切片与指针。
//
// 口径照 dsh-compaction-instant（vendor/dsh-compaction-instant/src/compiler.js）：
//   · 分词是字符类启发式——字母串 / 数字串 / 单个标点 / 空白串各一单位，空白不计；
//   · token 估计取 max(词类计数, DeepSeek 文档密度)（非 CJK 0.3、CJK 0.6 每字符）；
//   · brief-mode 只保留能指回原文的最小信息：工具调用压一行并带 `-> (seq N)`，
//     工具结果不抄正文，reasoning 不进台账，图像写 `[image]`；
//   · 产物是一段 `<checkpoint covers="a-b">…</checkpoint>` 文本。

import type { ChatMessage, ToolCall } from '../loop/Types.ts';

/** 词类分词：连续字母、连续数字、单个标点、空白串。 */
const TOKEN_RE: RegExp = /[A-Za-z]+|[0-9]+|[^\sA-Za-z0-9]|\s+/g;

/** 每条消息正文进台账的上限（字符）。 */
const ENTRY_TEXT_CHARS: number = 400;

export function tokenize(text: string): string[] {
  const found: string[] | null = text.match(TOKEN_RE);
  return found === null ? [] : found;
}

/** 非空白词单位计数，与 VCC 的 countTokens 同口径。 */
export function countTokens(text: string): number {
  let count: number = 0;
  for (const token of tokenize(text)) {
    if (token.trim().length > 0) {
      count += 1;
    }
  }
  return count;
}

function isCjkChar(char: string): boolean {
  const code: number = char.codePointAt(0) === undefined ? 0 : (char.codePointAt(0) as number);
  return (code >= 0x3400 && code <= 0x4dbf) || (code >= 0x4e00 && code <= 0x9fff) ||
    (code >= 0xf900 && code <= 0xfaff) || (code >= 0x3000 && code <= 0x303f) ||
    (code >= 0xff00 && code <= 0xffef);
}

/** DeepSeek 文档口径的字符密度估计（非 CJK 0.3、CJK 0.6 每字符）。 */
export function estimateDeepSeekTokens(text: string): number {
  let nonCjk: number = 0;
  let cjk: number = 0;
  for (const char of text) {
    if (isCjkChar(char)) {
      cjk += 1;
    } else {
      nonCjk += 1;
    }
  }
  return (nonCjk * 3 + cjk * 6) / 10;
}

/** 一条台账条目的预算尺寸：词类计数与密度估计取大。 */
export function estimateEntryTokens(text: string): number {
  return Math.max(countTokens(text), Math.ceil(estimateDeepSeekTokens(text)));
}

/** 清掉回车、ANSI 转义与控制字节；只做清理，不改写内容。 */
export function sanitize(text: string): string {
  return text.replace(/\r/g, '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');
}

/** 已知噪音包装：技能目录这类整块注入在台账里只留标记。 */
const NOISE_PATTERNS: RegExp[] = [
  /<skill-catalog>[\s\S]*?<\/skill-catalog>/g,
  /<system-reminder>[\s\S]*?<\/system-reminder>/g
];

export function stripNoise(text: string): string {
  let out: string = text;
  for (const pattern of NOISE_PATTERNS) {
    out = out.replace(pattern, '[catalog]');
  }
  return out;
}

function clip(text: string, limit: number): string {
  if (text.length <= limit) {
    return text;
  }
  return text.substring(0, limit) + '…';
}

/** 工具调用压成一行：白名单工具带关键参数，其余只留名字。 */
const ARG_TOOLS: Set<string> = new Set<string>(['read', 'write', 'edit', 'shell', 'grep', 'glob']);

function keyArgument(name: string, call: ToolCall): string {
  if (!ARG_TOOLS.has(name)) {
    return '';
  }
  const raw: string = call.argumentsJson === undefined ? '' : call.argumentsJson;
  try {
    const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const candidates: string[] = ['path', 'file', 'command', 'cmd', 'pattern', 'query'];
    for (const key of candidates) {
      const value: Object = parsed[key];
      if (value !== undefined && value !== null && typeof value === 'string') {
        return ' ' + clip(value as string, 80);
      }
    }
  } catch (error) {
    return ' ' + clip(raw, 80);
  }
  return '';
}

/** 台账里的一行工具调用：`* read a.ts -> result 5`。 */
function toolLine(call: ToolCall, seq: number, resultSeq: number): string {
  const name: string = call.name === undefined ? 'tool' : call.name;
  const tail: string = resultSeq > 0 ? ' -> result ' + resultSeq : '';
  return '* ' + name + keyArgument(name, call) + ' (' + seq + ')' + tail;
}

export interface CheckpointInput {
  /** 与 messages 一一对应的 seq，用来写 `(seq N)` 指针与 covers 范围。 */
  seqs: number[];
  messages: ChatMessage[];
  /** call id → 结果消息的 seq。 */
  resultSeqs: Map<string, number>;
  /** 这次编译覆盖了多少轮。 */
  turns: number;
}

export interface Checkpoint {
  text: string;
  /** 台账条目数（不含包装行）。 */
  entries: number;
  /** 台账本身的 token 估计。 */
  tokens: number;
}

/**
 * 把一段历史编译成 checkpoint 文本。只做切片与压缩，不生成新句子：
 * 用户与助手正文截断到 400 字符，工具结果只留指针，reasoning 与图像不进正文。
 */
export function compileCheckpoint(input: CheckpointInput): Checkpoint {
  const lines: string[] = [];
  const first: number = input.seqs.length > 0 ? input.seqs[0] : 0;
  const last: number = input.seqs.length > 0 ? input.seqs[input.seqs.length - 1] : 0;
  lines.push('<checkpoint covers="' + first + '-' + last + '" turns="' + input.turns + '">');
  let entries: number = 0;
  for (let i = 0; i < input.messages.length; i++) {
    const message: ChatMessage = input.messages[i];
    const seq: number = input.seqs[i];
    if (message.role === 'system') {
      continue;
    }
    if (message.role === 'tool') {
      // 工具结果不抄正文：调用行上的 `-> result N` 就是指针。
      continue;
    }
    if (message.role === 'assistant') {
      let text: string = stripNoise(sanitize(message.content)).trim();
      if (message.images !== undefined && message.images.length > 0) {
        text = (text.length > 0 ? text + ' ' : '') + '[image]';
      }
      const calls: string[] = [];
      for (const call of message.toolCalls) {
        const resultSeq: number = input.resultSeqs.get(call.id) === undefined
          ? 0 : input.resultSeqs.get(call.id) as number;
        calls.push(toolLine(call, seq, resultSeq));
      }
      const body: string = text.length > 0 ? clip(text, ENTRY_TEXT_CHARS) : '';
      if (body.length === 0 && calls.length === 0) {
        continue;
      }
      lines.push('[seq ' + seq + '] assistant: ' + body);
      entries += 1;
      for (const line of calls) {
        lines.push('  ' + line);
        entries += 1;
      }
      continue;
    }
    // 旧 checkpoint 不再整段进入新台账：折成一行指针，原体靠 recall 取回。
    if (message.content.indexOf('<checkpoint') === 0) {
      lines.push('[seq ' + seq + '] checkpoint: [checkpoint @ seq ' + seq + ']');
      entries += 1;
      continue;
    }
    // user（含 runtime 注入）
    const text: string = clip(stripNoise(sanitize(message.content)).trim(), ENTRY_TEXT_CHARS);
    if (text.length === 0) {
      continue;
    }
    const label: string = message.source === 'runtime' ? 'context' : 'user';
    lines.push('[seq ' + seq + '] ' + label + ': ' + text);
    entries += 1;
  }
  lines.push('</checkpoint>');
  const text: string = lines.join('\n');
  return { text: text, entries: entries, tokens: estimateEntryTokens(text) };
}

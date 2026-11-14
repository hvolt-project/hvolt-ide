// Resolving the pointers a checkpoint leaves behind.
//
// A compacted range is replaced by a summary that may quote fragments and `(seq N)` pointers. The
// pointers are worth nothing unless something resolves them against the log, which is this: the
// mode that takes an id (or a span) and returns what was actually written, and the mode that finds
// which seqs mention a word.
//
// The log is the source, never the surface: what comes back here is the original text, including
// ranges a compaction hid from the model.

import type { SessionEvent } from '../session/Events.ts';
import type { ToolCall } from './Types.ts';
import { ASSISTANT_MESSAGE, SYSTEM_MESSAGE, TOOL_RESULT, USER_MESSAGE } from '../session/Events.ts';

/** Longest single message handed back, so one recall cannot refill the context it was saving. */
const MAX_BODY = 4000;
/** Characters of context shown around a search hit. */
const HIT_WINDOW = 160;
/** How many hits a search may return when the caller does not say. */
const DEFAULT_LIMIT = 5;

export interface RecallRequest {
  /** A seq ("12") or an inclusive span ("3-7"). */
  seq?: string;
  /** Free text to search for in message bodies. */
  query?: string;
  limit?: number;
}

/** Parses "12" or "3-7"; null when the text is neither. */
export function parseSeq(text: string): number[] | null {
  const body = text.trim();
  if (body.length === 0) {
    return null;
  }
  const dash = body.indexOf('-');
  if (dash < 0) {
    const only = Number(body);
    return Number.isInteger(only) && only >= 0 ? [only, only] : null;
  }
  const from = Number(body.substring(0, dash).trim());
  const to = Number(body.substring(dash + 1).trim());
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from) {
    return null;
  }
  return [from, to];
}

function clip(text: string): string {
  if (text.length <= MAX_BODY) {
    return text;
  }
  return text.substring(0, MAX_BODY) + '\n…（本条另有 ' + (text.length - MAX_BODY) + ' 字符）';
}

function isMessageType(event: SessionEvent): boolean {
  return event.type === USER_MESSAGE || event.type === ASSISTANT_MESSAGE ||
    event.type === TOOL_RESULT || event.type === SYSTEM_MESSAGE;
}

/** Every message inside an inclusive seq range, oldest first. */

/**
 * 事件里的消息体。现在的日志是 {type, seq, time, data:{message}}；早期日志把 content/calls
 * 摊在顶层。两种都要能读，否则 recall 对着新日志会直接抛 event.calls is not iterable。
 */
function bodyOf(event: SessionEvent): string {
  const data = event.data as Record<string, Object> | undefined;
  if (data !== undefined && data !== null) {
    const message = data['message'];
    if (message !== undefined && message !== null) {
      const content = (message as Record<string, Object>)['content'];
      if (typeof content === 'string') {
        return content as string;
      }
    }
  }
  const flat = (event as Record<string, Object>)['content'];
  return typeof flat === 'string' ? flat as string : '';
}

/** 事件里的工具调用；同样兼容 data.message 与旧扁平字段。 */
function callsOf(event: SessionEvent): ToolCall[] {
  const data = event.data as Record<string, Object> | undefined;
  if (data !== undefined && data !== null) {
    const message = data['message'];
    if (message !== undefined && message !== null) {
      const calls = (message as Record<string, Object>)['toolCalls'];
      if (calls !== undefined && calls !== null) {
        return calls as ToolCall[];
      }
    }
  }
  const flat = (event as Record<string, Object>)['calls'];
  return flat === undefined || flat === null ? [] : flat as ToolCall[];
}

export function readRange(events: SessionEvent[], from: number, to: number): string {
  const parts: string[] = [];
  for (const event of events) {
    if (!isMessageType(event) || event.seq < from || event.seq > to) {
      continue;
    }
    const calls: string[] = [];
    for (const call of callsOf(event)) {
      calls.push(call.name + (call.argumentsJson.length > 0 ? ' ' + call.argumentsJson : ''));
    }
    const tail = calls.length > 0 ? '\n  calls: ' + calls.join(' | ') : '';
    parts.push('[seq ' + event.seq + '] ' + event.type + ': ' + clip(bodyOf(event)) + tail);
  }
  if (parts.length === 0) {
    return 'seq ' + from + '-' + to + ' 没有记录';
  }
  return parts.join('\n\n');
}

/** The window of text around the first occurrence of `needle` in `body`. */
export function hitWindow(body: string, needle: string): string {
  const at = body.toLowerCase().indexOf(needle.toLowerCase());
  if (at < 0) {
    return '';
  }
  const start = Math.max(0, at - HIT_WINDOW / 2);
  const end = Math.min(body.length, at + needle.length + HIT_WINDOW / 2);
  const head = start > 0 ? '…' : '';
  const tail = end < body.length ? '…' : '';
  return head + body.substring(start, end).replace(/\n/g, ' ') + tail;
}

/** Messages whose body mentions `needle`, newest last, at most `limit` of them. */
export function search(events: SessionEvent[], needle: string, limit: number): string {
  const hits: string[] = [];
  for (const event of events) {
    if (!isMessageType(event)) {
      continue;
    }
    if (bodyOf(event).toLowerCase().indexOf(needle.toLowerCase()) < 0) {
      continue;
    }
    hits.push('[seq ' + event.seq + '] ' + event.type + ': ' + hitWindow(bodyOf(event), needle));
    if (hits.length >= limit) {
      break;
    }
  }
  if (hits.length === 0) {
    return '没有匹配「' + needle + '」的记录';
  }
  return hits.join('\n');
}

/** Resolves one recall call against the log. */
export function recallEvents(events: SessionEvent[], request: RecallRequest): string {
  const limit = request.limit === undefined || request.limit <= 0 ? DEFAULT_LIMIT : request.limit;
  const seq = request.seq === undefined ? '' : request.seq.trim();
  if (seq.length > 0) {
    const range = parseSeq(seq);
    if (range === null) {
      return 'seq 需要写成 "12" 或 "3-7"';
    }
    return readRange(events, range[0], range[1]);
  }
  const query = request.query === undefined ? '' : request.query.trim();
  if (query.length > 0) {
    return search(events, query, limit);
  }
  return '给 seq（如 "12" 或 "3-7"）取原文，或给 query 搜索。';
}
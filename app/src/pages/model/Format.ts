// Text shaping for what the shell shows: which line of a failure is worth surfacing, how a turn's
// cost reads, and how a rolling log buffer is trimmed.
//
// No ArkUI and no platform calls, so the edge cases here run under `node --test`.

import type { Usage } from '../harness/loop/Types.ts';

/** The line worth showing from a tool's output. The captured stdout carries the WebView's own
 *  logging too, so the failure marker is picked out rather than trusting the first line. */
export function firstLine(text: string): string {
  const lines = text.trim().split('\n');
  for (const line of lines) {
    if (line.indexOf('\u2717') >= 0) {
      return line.trim();
    }
  }
  return lines.length > 0 ? lines[0].trim() : '';
}

/** One line at the end of a turn: what it cost and how long it took. */
export function statLine(usage: Usage, rounds: number, millis: number): string {
  const parts: string[] = [];
  parts.push((millis / 1000).toFixed(1) + 's');
  if (usage.totalTokens > 0) {
    parts.push('in ' + usage.promptTokens + ' \u00b7 out ' + usage.completionTokens);
    if (usage.reasoningTokens > 0) {
      parts.push('\u601d\u8003 ' + usage.reasoningTokens);
    }
  }
  if (rounds > 1) {
    parts.push(rounds + ' \u8f6e');
  }
  return parts.join(' \u00b7 ');
}

/** Appends fetched lines to a rolling buffer and keeps at most `limit` of them. The oldest go
 *  first, so the newest output survives no matter how long the stream runs. */
export function mergeTail(existing: string, incoming: string[], limit: number): string {
  const kept: string[] = existing.length === 0 ? [] : existing.split('\n');
  for (const line of incoming) {
    kept.push(line);
  }
  if (limit <= 0) {
    return '';
  }
  while (kept.length > limit) {
    kept.shift();
  }
  return kept.join('\n');
}

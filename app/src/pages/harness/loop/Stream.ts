// Decoding for the streaming chat response: framing the SSE lines and applying each delta.
//
// Separated from the transport so the parts that decide what text and tool calls the model sent
// can be tested without a socket. The transport keeps only the request and the chunk callback.

import type { ToolCall, Usage } from './Types.ts';

export interface ToolCallChunk {
  index: number;
  id: string;
  name: string;
  argumentsJson: string;
}

/** What a parsed delta reports back. Optional members are absent when the stream omits them. */
export interface DeltaSink {
  onText?: (piece: string) => void;
  onThought?: (piece: string) => void;
  onUsage?: (usage: Usage) => void;
}

/** Splits a buffer into whole SSE lines, returning the lines and the remainder to carry over.
 *  A chunk boundary can fall anywhere, including mid-line, so the tail is never parsed. */
export function cutLines(buffer: string): string[][] {
  const result: string[][] = [[], []];
  let rest = buffer;
  let cut = rest.indexOf('\n');
  while (cut >= 0) {
    result[0].push(rest.substring(0, cut).trim());
    rest = rest.substring(cut + 1);
    cut = rest.indexOf('\n');
  }
  result[1].push(rest);
  return result;
}

/** The JSON body of a `data:` line, or an empty string for anything else (comments, blank
 *  separators, and the `[DONE]` sentinel). */
export function ssePayload(line: string): string {
  const trimmed = line.trim();
  if (!trimmed.startsWith('data:')) {
    return '';
  }
  const payload = trimmed.substring(5).trim();
  return payload === '[DONE]' ? '' : payload;
}

function numberOr(value: Object, fallback: number): number {
  return value === undefined || value === null ? fallback : value as number;
}

/** Applies one delta payload. Text accumulates in `text` and tool calls in `calls`; the return
 *  value is the text so far, which is what the loop keeps as the round's answer. */
export function applyDelta(payload: string, text: string[], calls: Map<number, ToolCallChunk>,
  sink: DeltaSink): string {
  let parsed: Record<string, Object> | null = null;
  try {
    parsed = JSON.parse(payload) as Record<string, Object>;
  } catch (e) {
    return text.join('');
  }
  if (parsed === null) {
    return text.join('');
  }

  const reported = parsed['usage'] as Record<string, Object>;
  if (reported !== undefined && reported !== null && sink.onUsage !== undefined) {
    const details = reported['completion_tokens_details'] as Record<string, Object>;
    // Providers spell the cache split differently and all of them in the same OpenAI-shaped body:
    // DeepSeek reports `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`, OpenAI reports
    // `prompt_tokens_details.cached_tokens`, Anthropic reports `cache_read_input_tokens` and
    // `cache_creation_input_tokens`. Reading the first present spelling means one parser serves all
    // of them; when none is present the cache read is 0 and the whole prompt counts as uncached.
    const promptDetail = reported['prompt_tokens_details'] as Record<string, Object>;
    const prompt = numberOr(reported['prompt_tokens'], 0);
    let cacheRead = numberOr(reported['prompt_cache_hit_tokens'],
      numberOr(reported['cache_read_input_tokens'], 0));
    if (cacheRead === 0 && promptDetail !== undefined && promptDetail !== null) {
      cacheRead = numberOr(promptDetail['cached_tokens'], 0);
    }
    const cacheWrite = numberOr(reported['cache_creation_input_tokens'],
      numberOr(reported['prompt_cache_write_tokens'], 0));
    const uncached = numberOr(reported['prompt_cache_miss_tokens'],
      Math.max(0, prompt - cacheRead - cacheWrite));
    sink.onUsage({
      uncachedInputTokens: uncached,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      completionTokens: numberOr(reported['completion_tokens'], 0),
      reasoningTokens: details === undefined || details === null ? 0 :
        numberOr(details['reasoning_tokens'], 0),
      elapsedMs: 0
    });
  }

  const choices = parsed['choices'] as Object[];
  if (choices === undefined || choices === null || choices.length === 0) {
    return text.join('');
  }
  const first = choices[0] as Record<string, Object>;
  // Why a stream ended matters: `length` means the budget ran out before any content, which looks
  // identical to a model that simply said nothing.
  const finish = first['finish_reason'];
  if (finish !== undefined && finish !== null && sink.onFinish !== undefined) {
    sink.onFinish(String(finish));
  }
  const delta = first['delta'] as Record<string, Object>;
  if (delta === undefined || delta === null) {
    return text.join('');
  }

  const thought = delta['reasoning_content'] !== undefined && delta['reasoning_content'] !== null
    ? delta['reasoning_content'] : delta['reasoning'];
  if (thought !== undefined && thought !== null && sink.onThought !== undefined) {
    const piece = thought as string;
    if (piece.length > 0) {
      sink.onThought(piece);
    }
  }

  const content = delta['content'];
  if (content !== undefined && content !== null) {
    const piece = content as string;
    text.push(piece);
    if (sink.onText !== undefined) {
      sink.onText(piece);
    }
  }

  const rawCalls = delta['tool_calls'] as Object[];
  if (rawCalls !== undefined && rawCalls !== null) {
    for (const raw of rawCalls) {
      const part = raw as Record<string, Object>;
      const index = numberOr(part['index'], 0);
      let running = calls.get(index);
      if (running === undefined) {
        running = { index: index, id: '', name: '', argumentsJson: '' };
        calls.set(index, running);
      }
      if (part['id'] !== undefined && part['id'] !== null) {
        running.id = part['id'] as string;
      }
      const fn = part['function'] as Record<string, Object>;
      if (fn !== undefined && fn !== null) {
        if (fn['name'] !== undefined && fn['name'] !== null) {
          running.name = fn['name'] as string;
        }
        if (fn['arguments'] !== undefined && fn['arguments'] !== null) {
          running.argumentsJson += fn['arguments'] as string;
        }
      }
    }
  }
  return text.join('');
}

/** Tool calls in index order, with the fallbacks the loop needs to answer a nameless call. */
export function collectCalls(chunks: Map<number, ToolCallChunk>): ToolCall[] {
  const out: ToolCall[] = [];
  chunks.forEach((chunk: ToolCallChunk) => {
    if (chunk.name.length > 0) {
      out.push({
        id: chunk.id.length > 0 ? chunk.id : 'call_' + chunk.index,
        name: chunk.name,
        argumentsJson: chunk.argumentsJson.length > 0 ? chunk.argumentsJson : '{}'
      });
    }
  });
  return out;
}

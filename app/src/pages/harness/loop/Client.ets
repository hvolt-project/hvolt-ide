// Streaming chat client for an OpenAI-compatible endpoint.
//
// The transport does one thing: turn response bytes into text deltas and tool calls. It does not
// know which tools exist and never executes anything.

import hilog from '@ohos.hilog';
import http from '@ohos.net.http';
import util from '@ohos.util';
import { TOOLS } from '../mcp/Registry';
import { ChatMessage, ToolCall, Usage } from './Types';
import { LlmConfig } from './Settings';
import { applyDelta, collectCalls, ToolCallChunk } from './Stream';
import { chatUrl } from './Urls';

export interface StreamSink {
  onText: (delta: string) => void;
  /** Reasoning deltas, when the model emits them (reasoning_content or reasoning). */
  onThought?: (delta: string) => void;
  onToolCall: (call: ToolCall) => void;
  /** Token usage for this request, when the endpoint reports it. */
  onUsage?: (usage: Usage) => void;
  /** finish_reason for this request: `length` means the budget ran out before any content. */
  onFinish?: (reason: string) => void;
  onDone: () => void;
  onError: (message: string) => void;
}


/**
 * 面板上只放一句人话。模型端点出错时返回的 JSON 原文动辄几百字，直接甩到对话里
 * 谁都读不下去，原文进 hilog 留证，界面只给状态码与一条原因。
 */
function explainHttpError(status: number, detail: string): string {
  let message = '';
  try {
    const parsed = JSON.parse(detail) as Record<string, Object>;
    const nested = parsed['error'];
    if (nested !== undefined && nested !== null && typeof nested === 'object') {
      const inner = (nested as Record<string, Object>)['message'];
      if (typeof inner === 'string') {
        message = inner;
      }
    }
    if (message.length === 0) {
      const flat = parsed['message'];
      if (typeof flat === 'string') {
        message = flat;
      }
    }
  } catch (e) {
  }
  if (message.length === 0) {
    const cut = detail.indexOf('\n');
    message = cut > 0 ? detail.substring(0, cut) : detail;
  }
  message = message.trim();
  if (message.length > 120) {
    message = message.substring(0, 120) + '…';
  }
  return message.length > 0
    ? '请求失败（HTTP ' + status + '）：' + message
    : '请求失败（HTTP ' + status + '）';
}

/**
 * 把孤立的代理项换成 U+FFFD，保证文本能编码成 UTF-8。
 * 工具结果可能带半个码元，原样发回去会让整个请求体非法。
 */
function wellFormed(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
      if (next >= 0xdc00 && next <= 0xdfff) {
        out += text.charAt(i) + text.charAt(i + 1);
        i++;
      } else {
        out += '\ufffd';
      }
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      out += '\ufffd';
    } else {
      out += text.charAt(i);
    }
  }
  return out;
}

/** Cancellation flag shared with the caller: set `.cancelled` to stop after the current chunk. */
export class AbortFlag {
  cancelled: boolean = false;
}

/**
 * One message as the wire expects it.
 *
 * Removed by accident when the stream decoder was extracted; the call site stayed, so every send
 * failed with "toWire is not defined". Restored verbatim from the version before that commit.
 */
function toWire(messages: ChatMessage[]): Object[] {
  const out: Object[] = [];
  for (const message of messages) {
    // The runtime block rides with the request but is not part of what the user said.
    const body = wellFormed(
      message.context.length > 0 ? message.context + '\n\n' + message.content : message.content);
    const row: Record<string, Object> = { 'role': message.role, 'content': body };
    if (message.images.length > 0) {
      // Multimodal content: the text part plus one image part per attachment.
      const parts: Object[] = [{ 'type': 'text', 'text': body }];
      for (const image of message.images) {
        parts.push({ 'type': 'image_url', 'image_url': { 'url': image } });
      }
      row['content'] = parts;
    }
    if (message.toolCalls.length > 0) {
      const calls: Object[] = [];
      for (const call of message.toolCalls) {
        const fn: Record<string, Object> = { 'name': call.name, 'arguments': wellFormed(call.argumentsJson) };
        calls.push({ 'id': call.id, 'type': 'function', 'function': fn });
      }
      row['tool_calls'] = calls;
    }
    if (message.toolCallId.length > 0) {
      row['tool_call_id'] = message.toolCallId;
    }
    out.push(row);
  }
  return out;
}

/**
 * The tool table as the /chat/completions request expects it.
 *
 * Deleted together with toWire when the stream decoder was extracted; the call site stayed. Restored
 * from the version before that commit.
 */
function toolSchema(): Object[] {
  const out: Object[] = [];
  for (const spec of TOOLS.descriptors()) {
    const fn: Record<string, Object> = {
      'name': spec['name'],
      'description': spec['description'],
      'parameters': spec['inputSchema']
    };
    const entry: Record<string, Object> = { 'type': 'function', 'function': fn };
    out.push(entry);
  }
  return out;
}

export async function streamChat(config: LlmConfig, messages: ChatMessage[], sink: StreamSink,
  abort: AbortFlag): Promise<void> {
  if (!config.ready()) {
    sink.onError('model endpoint is not configured');
    return;
  }
  // 字段集照 dsh-llm-deepseek 的请求形状：没有 stream_options，工具表为空时整个字段省略，
  // 空数组和多出来的 stream_options 都会被严格的端点判成 400。
  const body: Record<string, Object> = {
    'model': config.model,
    'messages': toWire(messages),
    'stream': true
  };
  const schema = toolSchema();
  if (schema.length > 0) {
    body['tools'] = schema;
  }
  // Only sent when chosen: an endpoint that does not know the field should not choke on it.
  if (config.effort.length > 0) {
    body['reasoning_effort'] = config.effort;
  }
  // Logged at both ends: a request that never returns leaves no trace anywhere else, which is
  // indistinguishable from a dead UI.
  let shape = '';
  for (let index = 0; index < messages.length; index += 1) {
    const m = messages[index];
    // Content length and call count only: enough to see a dropped or duplicated turn without
    // writing the conversation into the system log.
    shape += index + ':' + m.role + '/' + m.content.length +
      (m.context.length > 0 ? '+ctx' + m.context.length : '') +
      (m.toolCalls.length > 0 ? '+call' + m.toolCalls.length : '') +
      (m.toolCallId.length > 0 ? '+id' : '') + ' ';
  }
  hilog.info(0x0000, 'hvoltide', 'request start: %{public}d messages [%{public}s]', messages.length, shape);
  const request = http.createHttp();
  const decoder = util.TextDecoder.create('utf-8');
  const text: string[] = [];
  const calls: Map<number, ToolCallChunk> = new Map();
  let carry = '';
  let finished = false;

  // Non-SSE lines: a refused request answers with a JSON body rather than an event stream, and
  // dropping those lines silently turns an error into an empty reply.
  let raw = '';
  request.on('dataReceive', (chunk: ArrayBuffer) => {
    if (abort.cancelled) {
      return;
    }
    // Stream decoding: a multi-byte character can straddle two chunks, and decoding each
    // chunk on its own would corrupt it.
    carry += decoder.decodeWithStream(new Uint8Array(chunk), { stream: true });
    let cut = carry.indexOf('\n');
    while (cut >= 0) {
      const line = carry.substring(0, cut).trim();
      carry = carry.substring(cut + 1);
      cut = carry.indexOf('\n');
      if (!line.startsWith('data:')) {
        if (line.length > 0) {
          raw += line;
        }
        continue;
      }
      const payload = line.substring(5).trim();
      if (payload === '[DONE]') {
        finished = true;
        continue;
      }
      applyDelta(payload, text, calls, sink);
    }
  });

  try {
    const status: number = await request.requestInStream(chatUrl(config.baseUrl), {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + config.token
      },
      extraData: JSON.stringify(body),
      connectTimeout: 30000,
      readTimeout: 60000
    });
    if (status >= 400) {
      // The streaming API reports the status but not the body of a refusal, so ask once more
      // without streaming to get the message the endpoint actually sent.
      let detail = raw;
      if (detail.length === 0) {
        const probe = http.createHttp();
        try {
          const answer = await probe.request(chatUrl(config.baseUrl), {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ' + config.token
            },
            extraData: JSON.stringify(body),
            connectTimeout: 30000,
            readTimeout: 30000
          });
          detail = answer.result === undefined || answer.result === null ? '' : String(answer.result);
        } catch (e) {
          detail = '(无法读取错误正文: ' + (e as Error).message + ')';
        } finally {
          probe.destroy();
        }
      }
      hilog.warn(0x0000, 'hvoltide', 'request http %{public}d: %{public}s', status, detail);
      hilog.error(0x0000, 'hvoltide', 'http %{public}d body: %{public}s', status,
        detail.substring(0, 2000));
      sink.onError(explainHttpError(status, detail));
      return;
    }
    const pending = collectCalls(calls);
    if (text.length === 0 && pending.length === 0 && raw.length > 0 && !finished) {
      // A 200 that carries no event stream at all: report the body instead of ending the turn.
      hilog.warn(0x0000, 'hvoltide', 'request non-stream body: %{public}s', raw);
      sink.onError('unexpected response: ' + raw.substring(0, 400));
      return;
    }
    for (const call of pending) {
      sink.onToolCall(call);
    }
    if (!finished && carry.trim().length > 0 && carry.trim().startsWith('data:')) {
      const payload = carry.trim().substring(5).trim();
      if (payload !== '[DONE]') {
        applyDelta(payload, text, calls, sink);
      }
    }
    sink.onDone();
  } catch (e) {
    hilog.warn(0x0000, 'hvoltide', 'request failed: %{public}s', (e as Error).message);
    sink.onError((e as Error).message);
  } finally {
    request.destroy();
  }
}

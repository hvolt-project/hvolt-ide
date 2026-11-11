// Streaming chat client for an OpenAI-compatible endpoint.
//
// The transport does one thing: turn response bytes into text deltas and tool calls. It does not
// know which tools exist and never executes anything.

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
  onDone: () => void;
  onError: (message: string) => void;
}

/** Cancellation flag shared with the caller: set `.cancelled` to stop after the current chunk. */
export class AbortFlag {
  cancelled: boolean = false;
}

export async function streamChat(config: LlmConfig, messages: ChatMessage[], sink: StreamSink,
  abort: AbortFlag): Promise<void> {
  if (!config.ready()) {
    sink.onError('model endpoint is not configured');
    return;
  }
  const body: Record<string, Object> = {
    'model': config.model,
    'messages': toWire(messages),
    'tools': toolSchema(),
    'stream': true,
    // Without this the streaming response carries no usage block at all.
    'stream_options': { 'include_usage': true }
  };
  // Only sent when chosen: an endpoint that does not know the field should not choke on it.
  if (config.effort.length > 0) {
    body['reasoning_effort'] = config.effort;
  }
  const request = http.createHttp();
  const decoder = util.TextDecoder.create('utf-8');
  const text: string[] = [];
  const calls: Map<number, ToolCallChunk> = new Map();
  let carry = '';
  let finished = false;

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
    await request.requestInStream(chatUrl(config.baseUrl), {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + config.token
      },
      extraData: JSON.stringify(body),
      connectTimeout: 30000,
      readTimeout: 120000
    });
    for (const call of collectCalls(calls)) {
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
    sink.onError((e as Error).message);
  } finally {
    request.destroy();
  }
}

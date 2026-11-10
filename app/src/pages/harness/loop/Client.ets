// Streaming chat client for an OpenAI-compatible endpoint.
//
// The transport does one thing: turn response bytes into text deltas and tool calls. It does not
// know which tools exist and never executes anything.

import http from '@ohos.net.http';
import util from '@ohos.util';
import { TOOLS } from '../mcp/Registry';
import { ChatMessage, ToolCall } from './Types';
import { LlmConfig } from './Settings';
import { chatUrl } from './Models';

export interface StreamSink {
  onText: (delta: string) => void;
  /** Reasoning deltas, when the model emits them (reasoning_content or reasoning). */
  onThought?: (delta: string) => void;
  onToolCall: (call: ToolCall) => void;
  onDone: () => void;
  onError: (message: string) => void;
}

/** Cancellation flag shared with the caller: set `.cancelled` to stop after the current chunk. */
export class AbortFlag {
  cancelled: boolean = false;
}

interface ToolCallChunk {
  index: number;
  id: string;
  name: string;
  argumentsJson: string;
}

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

function toWire(messages: ChatMessage[]): Object[] {
  const out: Object[] = [];
  for (const message of messages) {
    const row: Record<string, Object> = { 'role': message.role, 'content': message.content };
    if (message.toolCalls.length > 0) {
      const calls: Object[] = [];
      for (const call of message.toolCalls) {
        const fn: Record<string, Object> = { 'name': call.name, 'arguments': call.argumentsJson };
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

/** Applies one `data:` payload to the running accumulators. */
function applyDelta(payload: string, text: string[], calls: Map<number, ToolCallChunk>,
  sink: StreamSink): string {
  let parsed: Record<string, Object> | null = null;
  try {
    parsed = JSON.parse(payload) as Record<string, Object>;
  } catch (e) {
    return text.join('');
  }
  const choices = parsed['choices'] as Object[];
  if (choices === undefined || choices.length === 0) {
    return text.join('');
  }
  const first = choices[0] as Record<string, Object>;
  const delta = first['delta'] as Record<string, Object>;
  if (delta === undefined) {
    return text.join('');
  }
  const thought = delta['reasoning_content'] !== undefined ? delta['reasoning_content'] : delta['reasoning'];
  if (thought !== undefined && thought !== null && sink.onThought !== undefined) {
    sink.onThought(thought as string);
  }
  const content = delta['content'];
  if (content !== undefined && content !== null) {
    const piece = content as string;
    text.push(piece);
    sink.onText(piece);
  }
  const rawCalls = delta['tool_calls'] as Object[];
  if (rawCalls !== undefined) {
    for (const raw of rawCalls) {
      const part = raw as Record<string, Object>;
      const index = part['index'] === undefined ? 0 : part['index'] as number;
      let running = calls.get(index);
      if (running === undefined) {
        running = { index: index, id: '', name: '', argumentsJson: '' };
        calls.set(index, running);
      }
      const fn = part['function'] as Record<string, Object>;
      if (part['id'] !== undefined && part['id'] !== null) {
        running.id = part['id'] as string;
      }
      if (fn !== undefined) {
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
    'stream': true
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
    carry += decoder.decodeToString(new Uint8Array(chunk));
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
    calls.forEach((chunk: ToolCallChunk) => {
      if (chunk.name.length > 0) {
        sink.onToolCall({
          id: chunk.id.length > 0 ? chunk.id : 'call_' + chunk.index,
          name: chunk.name,
          argumentsJson: chunk.argumentsJson.length > 0 ? chunk.argumentsJson : '{}'
        });
      }
    });
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

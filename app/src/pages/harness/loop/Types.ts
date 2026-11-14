// The shapes the loop passes around. Kept separate from the transport so the client and the loop
// can be tested against each other without a network.

export type Role = 'system' | 'user' | 'assistant' | 'tool';

/** Who put this message into the conversation.
 *
 *  `role` is what the model is told; it cannot answer this, because the runtime writes into the
 *  same user slot the person types into. Every injected block — skill catalogue, reminders, the
 *  runtime snapshot — carries `runtime` here, so a reader decides what to draw from this field
 *  instead of matching text prefixes. */
export type MessageSource = 'human' | 'model' | 'tool' | 'runtime';

export interface ChatMessage {
  /** Log position, assigned when the message is appended. 0 until then. */
  id: number;
  role: Role;
  /** Who wrote it: the person, the model, a tool result, or the runtime. */
  source: MessageSource;
  content: string;
  /** Reasoning text, when the model emits one; kept so later turns can send it back. */
  reasoning: string;
  /** Per-turn runtime state sent alongside the message but never shown or stored as its text. */
  context: string;
  /** Images attached to this message, as data URLs. */
  images: string[];
  /** Set on assistant messages that ask for tools. */
  toolCalls: ToolCall[];
  /** Set on tool results: which call they answer. */
  toolCallId: string;
}

/** Token accounting for one request.
 *
 *  The three input buckets are disjoint and sum to what the provider billed as prompt-side input.
 *  `cacheReadTokens` is the part served from its prefix cache, which is the only cheap signal that
 *  the prompt prefix is actually being reused across turns: a single `promptTokens` number cannot
 *  answer that, and without it a cache regression looks exactly like a longer conversation. */
export interface Usage {
  uncachedInputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  completionTokens: number;
  reasoningTokens: number;
  /** 生成本身的用时（毫秒）：第一个增量到最后一块。0 表示没测到，不参与 tok/s。 */
  elapsedMs: number;
}

export function emptyUsage(): Usage {
  return {
    uncachedInputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
    completionTokens: 0, reasoningTokens: 0, elapsedMs: 0
  };
}

/** Prompt-side tokens the provider billed. */
export function billedInputTokens(usage: Usage): number {
  return usage.uncachedInputTokens + usage.cacheReadTokens + usage.cacheWriteTokens;
}

/** Everything the model cost, input and output together. */
export function totalTokensOf(usage: Usage): number {
  return billedInputTokens(usage) + usage.completionTokens;
}

export function addUsage(into: Usage, more: Usage): void {
  into.uncachedInputTokens += more.uncachedInputTokens;
  into.cacheReadTokens += more.cacheReadTokens;
  into.cacheWriteTokens += more.cacheWriteTokens;
  into.completionTokens += more.completionTokens;
  into.reasoningTokens += more.reasoningTokens;
}

export interface ToolCall {
  id: string;
  name: string;
  /** Raw JSON text as the model emitted it. */
  argumentsJson: string;
}

export function systemMessage(text: string): ChatMessage {
  return {
    id: 0, role: 'system', source: 'runtime', content: text, reasoning: '', context: '',
    images: [], toolCalls: [], toolCallId: ''
  };
}

/** `images` are data URLs; the previous signature had no such parameter, so callers that passed
 *  attachments had them silently dropped and `message.images` arrived undefined at the wire. */
export function userMessage(text: string, images: string[]): ChatMessage {
  return {
    id: 0, role: 'user', source: 'human', content: text, reasoning: '', context: '',
    images: images, toolCalls: [], toolCallId: ''
  };
}

/** 注入给模型看的上下文（技能目录、运行时提醒）：角色随 user 发送，但来源不是人，界面不显示。 */
export function runtimeMessage(text: string): ChatMessage {
  return {
    id: 0, role: 'user', source: 'runtime', content: text, reasoning: '', context: '',
    images: [], toolCalls: [], toolCallId: ''
  };
}

export function assistantMessage(text: string, calls: ToolCall[], reasoning: string): ChatMessage {
  return {
    id: 0, role: 'assistant', source: 'model', content: text, reasoning: reasoning, context: '',
    images: [], toolCalls: calls, toolCallId: ''
  };
}

export function toolMessage(callId: string, text: string): ChatMessage {
  return {
    id: 0, role: 'tool', source: 'tool', content: text, reasoning: '', context: '',
    images: [], toolCalls: [], toolCallId: callId
  };
}

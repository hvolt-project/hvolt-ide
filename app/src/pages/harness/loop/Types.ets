// The shapes the loop passes around. Kept separate from the transport so the client and the loop
// can be tested against each other without a network.

export type Role = 'system' | 'user' | 'assistant' | 'tool';

export interface ChatMessage {
  role: Role;
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

export interface Usage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  reasoningTokens: number;
}

export function emptyUsage(): Usage {
  return { promptTokens: 0, completionTokens: 0, totalTokens: 0, reasoningTokens: 0 };
}

export interface ToolCall {
  id: string;
  name: string;
  /** Raw JSON text as the model emitted it. */
  argumentsJson: string;
}

export function systemMessage(text: string): ChatMessage {
  return {
    role: 'system', content: text, reasoning: '', context: '', images: [],
    toolCalls: [], toolCallId: ''
  };
}

/** `images` are data URLs; the previous signature had no such parameter, so callers that passed
 *  attachments had them silently dropped and `message.images` arrived undefined at the wire. */
export function userMessage(text: string, images: string[]): ChatMessage {
  return {
    role: 'user', content: text, reasoning: '', context: '', images: images,
    toolCalls: [], toolCallId: ''
  };
}

export function assistantMessage(text: string, calls: ToolCall[], reasoning: string): ChatMessage {
  return {
    role: 'assistant', content: text, reasoning: reasoning, context: '', images: [],
    toolCalls: calls, toolCallId: ''
  };
}

export function toolMessage(callId: string, text: string): ChatMessage {
  return {
    role: 'tool', content: text, reasoning: '', context: '', images: [],
    toolCalls: [], toolCallId: callId
  };
}

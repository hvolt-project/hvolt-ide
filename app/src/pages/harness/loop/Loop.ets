// The loop: ask the model, run the tools it asks for, feed the results back, repeat until it
// stops asking. Deliberately small — one conversation, one tool table, no sub-agents.
//
// A tool that throws becomes a tool result, not a crash: the model sees "error: ..." and can
// change approach. The same holds for a denial from the approval gate.

import { TOOLS, ToolSpec } from '../mcp/Registry';
import { AbortFlag, streamChat } from './Client';
import { LlmConfig } from './Settings';
import { ChatMessage, ToolCall, assistantMessage, toolMessage, userMessage } from './Types';

export interface LoopSink {
  onText: (delta: string) => void;
  onToolStart: (call: ToolCall) => void;
  onToolResult: (callId: string, text: string) => void;
  onError: (message: string) => void;
  onDone: () => void;
}

const MAX_ROUNDS: number = 8;

export class ChatSession {
  private history: ChatMessage[] = [];
  private abort: AbortFlag = new AbortFlag();
  private running: boolean = false;

  /** Replaces the system prompt; called once the prompt file is loaded. */
  setSystem(text: string): void {
    const kept: ChatMessage[] = this.history.filter((m: ChatMessage) => m.role !== 'system');
    this.history = [];
    if (text.length > 0) {
      this.history.push({
        role: 'system', content: text, toolCalls: [], toolCallId: ''
      });
    }
    for (const message of kept) {
      this.history.push(message);
    }
  }

  reset(): void {
    this.abort.cancelled = true;
    this.abort = new AbortFlag();
    this.history = this.history.filter((m: ChatMessage) => m.role === 'system');
    this.running = false;
  }

  /** Stops after the current chunk; already streamed text is kept. */
  stop(): void {
    this.abort.cancelled = true;
  }

  busy(): boolean {
    return this.running;
  }

  messages(): ChatMessage[] {
    return this.history;
  }

  async send(config: LlmConfig, userText: string, sink: LoopSink): Promise<void> {
    if (this.running) {
      sink.onError('a turn is already running');
      return;
    }
    if (this.history.length === 0 || this.history[0].role !== 'system') {
      this.history.unshift({ role: 'system', content: '', toolCalls: [], toolCallId: '' });
    }
    this.history.push(userMessage(userText));
    this.running = true;
    this.abort = new AbortFlag();

    try {
      for (let round = 0; round < MAX_ROUNDS; round++) {
        if (this.abort.cancelled) {
          break;
        }
        const text: string[] = [];
        const calls: ToolCall[] = [];
        let failure = '';

        await streamChat(config, this.history, {
          onText: (delta: string) => {
            text.push(delta);
            sink.onText(delta);
          },
          onToolCall: (call: ToolCall) => {
            calls.push(call);
          },
          onDone: () => {
          },
          onError: (message: string) => {
            failure = message;
          }
        }, this.abort);

        const assembled = text.join('');
        this.history.push(assistantMessage(assembled, calls));
        if (failure.length > 0) {
          sink.onError(failure);
          break;
        }
        if (calls.length === 0) {
          break;
        }
        for (const call of calls) {
          if (this.abort.cancelled) {
            break;
          }
          sink.onToolStart(call);
          const result = await this.invoke(call);
          this.history.push(toolMessage(call.id, result));
          sink.onToolResult(call.id, result);
        }
      }
    } finally {
      this.running = false;
      sink.onDone();
    }
  }

  private async invoke(call: ToolCall): Promise<string> {
    const spec: ToolSpec | undefined = TOOLS.get(call.name);
    if (spec === undefined) {
      return 'error: no such tool: ' + call.name;
    }
    let args: Record<string, Object> = {};
    try {
      args = JSON.parse(call.argumentsJson) as Record<string, Object>;
    } catch (e) {
      return 'error: arguments are not valid JSON';
    }
    try {
      return await spec.handler(args);
    } catch (e) {
      return 'error: ' + (e as Error).message;
    }
  }
}

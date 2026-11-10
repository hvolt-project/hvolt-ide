// The loop: ask the model, run the tools it asks for, feed the results back, repeat until it
// stops asking. Deliberately small — one conversation, one tool table, no sub-agents.
//
// A tool that throws becomes a tool result, not a crash: the model sees "error: ..." and can
// change approach. The same holds for a denial from the approval gate.

import { TOOLS, ToolSpec } from '../mcp/Registry';
import { AbortFlag, streamChat } from './Client';
import { LlmConfig } from './Settings';
import { ChatMessage, Role, ToolCall, assistantMessage, toolMessage, userMessage } from './Types';

export interface LoopSink {
  onText: (delta: string) => void;
  onThought: (delta: string) => void;
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
        const thought: string[] = [];
        const calls: ToolCall[] = [];
        let failure = '';

        await streamChat(config, this.history, {
          onText: (delta: string) => {
            text.push(delta);
            sink.onText(delta);
          },
          onThought: (delta: string) => {
            thought.push(delta);
            sink.onThought(delta);
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
        this.history.push(assistantMessage(assembled, calls, thought.join('')));
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

  /**
   * One message per line (jsonl), system prompt excluded — it is rebuilt on load.
   *
   * A line per message rather than one JSON array: the file stays readable with grep, a partial
   * write costs one line instead of the whole conversation, and a future append-only writer does
   * not have to rewrite what is already there.
   */
  dump(): string {
    const lines: string[] = [];
    for (const message of this.history) {
      if (message.role === 'system') {
        continue;
      }
      const calls: Object[] = [];
      for (const call of message.toolCalls) {
        calls.push({ 'id': call.id, 'name': call.name, 'arguments': call.argumentsJson });
      }
      lines.push(JSON.stringify({
        'role': message.role,
        'content': message.content,
        'reasoning': message.reasoning,
        'calls': calls,
        'callId': message.toolCallId
      }));
    }
    return lines.join('\n');
  }

  /** Restores a jsonl dump; a malformed line is skipped rather than aborting the rest. */
  load(text: string): void {
    this.history = this.history.filter((m: ChatMessage) => m.role === 'system');
    if (text.trim().length === 0) {
      return;
    }
    for (const line of text.split('\n')) {
      if (line.trim().length === 0) {
        continue;
      }
      let row: Record<string, Object> | null = null;
      try {
        row = JSON.parse(line) as Record<string, Object>;
      } catch (e) {
        continue;
      }
      if (row === null || row['role'] === undefined) {
        continue;
      }
      const calls: ToolCall[] = [];
      const rawCalls = row['calls'] as Object[];
      if (rawCalls !== undefined && rawCalls !== null) {
        for (const entry of rawCalls) {
          const call = entry as Record<string, Object>;
          calls.push({
            id: call['id'] as string,
            name: call['name'] as string,
            argumentsJson: call['arguments'] as string
          });
        }
      }
      this.history.push({
        role: row['role'] as Role,
        content: row['content'] as string,
        reasoning: row['reasoning'] === undefined ? '' : row['reasoning'] as string,
        toolCalls: calls,
        toolCallId: row['callId'] === undefined ? '' : row['callId'] as string
      });
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

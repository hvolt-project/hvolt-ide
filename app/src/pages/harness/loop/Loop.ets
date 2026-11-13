// 一轮对话的执行器：一次发送拆成 turn 与 step，事件全部落在 session 日志里。
//
// 与 dsh-agent-loop/lib/index.js 的 turn()/step() 对齐：
//   turn/start → [step/start → 请求 → assistant/message → tool/call…tool/result → step/end] → turn/end
// 没有轮数上限：模型不再要求工具时才结束。空回复不重试，按 DSH 记一条 assistant/attempt 收尾。

import hilog from '@ohos.hilog';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { TOOLS, ToolSpec } from '../mcp/Registry';
import { AbortFlag, StreamSink, streamChat } from './Client';
import { runBatch } from './ToolBatch';
import { dispatch } from './Dispatch';
import { LlmConfig } from './Settings';
import { ChatMessage, ToolCall, Usage, assistantMessage, emptyUsage, runtimeMessage, systemMessage, userMessage } from './Types';
import { Session, priceOfMessage } from '../session/Session';
import { SessionStats } from '../session/Stats';
import { selectCompactableRange } from '../session/Compact';
import type { CompactOutcome, PricedNode, Region } from '../session/Compact';
import { recallEvents } from './Recall';

export type Transport = (config: LlmConfig, messages: ChatMessage[], sink: StreamSink,
  abort: AbortFlag) => Promise<void>;

export interface LoopSink {
  onText: (delta: string) => void;
  onThought: (delta: string) => void;
  onToolStart: (call: ToolCall) => void;
  onToolResult: (callId: string, text: string) => void;
  onError: (message: string) => void;
  onDone: () => void;
}

/** 压缩摘要的固定指令。 */
const COMPACTION_INSTRUCTION: string =
  'Summarize the conversation above so it can replace the original in context.\n\n' +
  'Write a dense brief the next turn can act on without re-reading anything. Use short sections, ' +
  'not prose paragraphs. Write "(none)" for an empty section — never drop a section.\n\n' +
  '## Primary Request and Intent\n' +
  '## Key Technical Concepts\n' +
  '## Files and Code\n' +
  '## Errors and Fixes\n' +
  '## Pending Jobs\n' +
  '## Current Work\n' +
  '## Next Step\n' +
  '## Critical Context\n\n' +
  'Rules: preserve exact paths, commands, error strings, identifiers and numbers. Capture user ' +
  'corrections faithfully. Do not mention this request or that the context was compacted. Output ' +
  'only the checkpoint text: do not call any tool or take any other action.';

/** 技能目录的标记：目录拼在系统提示里，读回时靠它拆开。 */
const CATALOG_TAG: string = '<!-- skill-catalog -->';

export class ChatSession {
  private session: Session = new Session('chat', '');

  /** 状态栏用的统计：转给内层会话折叠。 */
  stats(): SessionStats {
    return this.session.stats();
  }
  private abort: AbortFlag = new AbortFlag();
  private running: boolean = false;
  private requestHeaderLogged: boolean = false;
  private compactionId: string = '';
  private turn: number = 0;
  private step: number = 0;
  private systemSeq: number = -1;
  private systemText: string = '';
  private catalogBody: string = '';
  private transport: Transport = streamChat;
  /** 这一轮拍下的截图（data URL），下一次请求前附到消息里。 */
  private pendingShots: string[] = [];

  // --- 生命周期 --------------------------------------------------------------------------------

  /** 恢复历史；返回 false 表示文件不完整，调用方必须停止续写。 */
  load(text: string): boolean {
    const ok = this.session.load(text);
    this.systemSeq = -1;
    this.systemText = '';
    this.catalogBody = '';
    for (const seq of this.session.surfaceSeqs()) {
      const message = this.session.deriveEventMessage(seq);
      if (message !== undefined && message.role === 'system' && this.systemSeq < 0) {
        this.systemSeq = seq;
        this.splitSystem(message.content);
      }
    }
    return ok;
  }

  dump(): string {
    return this.session.dump();
  }

  eventCount(): number {
    return this.session.eventCount();
  }

  dumpSince(index: number): string {
    return this.session.dumpSince(index);
  }

  reset(): void {
    this.session = new Session('chat', '');
    this.systemSeq = -1;
    this.systemText = '';
    this.catalogBody = '';
  }

  /** 模型现在会收到的消息序列。 */
  messages(): ChatMessage[] {
    return this.session.messages();
  }

  /** 注入一段运行时上下文（DSH 的 agent.inject）：模型看得见，界面不显示。 */
  inject(text: string): void {
    if (text.trim().length === 0) {
      return;
    }
    this.session.append('user/message', runtimeMessage(text), 'append');
  }

  /** 完整对话，包含压缩已遮蔽的部分。 */
  transcript(): ChatMessage[] {
    return this.session.transcript(0);
  }

  setTransport(transport: Transport): void {
    this.transport = transport;
  }

  stop(): void {
    this.abort.cancelled = true;
  }

  recall(seq: string, query: string, limit: number): string {
    return recallEvents(this.session.all(), { seq: seq, query: query, limit: limit });
  }

  // --- 提示词 ----------------------------------------------------------------------------------

  /** 装系统提示。运行时上下文（技能目录）拼在它后面，不是另发一条消息。 */
  setSystem(text: string): void {
    this.systemText = text;
    this.applySystem();
  }

  /** 技能目录变了：重拼系统提示，不新增节点。 */
  setCatalog(text: string): void {
    const body = text.trim();
    this.catalogBody = body.length === 0 ? '' : CATALOG_TAG + '\n' + body;
    this.applySystem();
  }

  private applySystem(): void {
    const full = this.catalogBody.length === 0
      ? this.systemText : this.systemText + '\n\n' + this.catalogBody;
    if (full.trim().length === 0) {
      return;
    }
    const message = systemMessage(full);
    if (this.systemSeq >= 0) {
      const placed = this.session.append('system/message', { turn: Math.max(this.turn, 1), step: Math.max(this.step, 1), message: message }, { op: 'replace', startSeq: this.systemSeq, endSeq: this.systemSeq }, [this.systemSeq]);
      this.systemSeq = placed.seq;
      return;
    }
    const placed = this.session.append('system/message', { turn: Math.max(this.turn, 1), step: Math.max(this.step, 1), message: message }, 'append');
    this.systemSeq = placed.seq;
  }

  /** 把一条系统提示拆成「正文」与「目录」两段。 */
  private splitSystem(text: string): void {
    const at = text.indexOf(CATALOG_TAG);
    if (at < 0) {
      this.systemText = text;
      this.catalogBody = '';
      return;
    }
    this.systemText = text.substring(0, at).trim();
    this.catalogBody = text.substring(at);
  }

  setContextWindow(tokens: number): void {
    if (tokens > 0) {
      this.session.contextWindow = tokens;
      this.session.reservedCompletionTokens = 8192;
    }
  }

  // --- 一轮 ------------------------------------------------------------------------------------

  async send(config: LlmConfig, userText: string, context: string, images: string[],
    sink: LoopSink): Promise<void> {
    if (this.running) {
      sink.onError('a turn is already running');
      return;
    }
    this.running = true;
    this.abort = new AbortFlag();
    let closed = '';
    try {
      // 压缩在组装请求之前做，这一轮按缩小后的历史计价。
      await this.compactIfNeeded(config);
      this.turn += 1;
      this.step = 0;
      this.session.append('turn/start', { turn: this.turn });
      let firstStep = true;
      while (true) {
        if (this.abort.cancelled) {
          closed = 'cancelled';
          break;
        }
        this.step += 1;
        this.session.append('step/start', { turn: this.turn, step: this.step });
        if (firstStep) {
          // 人的话属于第一步：step/start 之后才进 surface
          const said = userMessage(userText, images);
          said.context = context;
          this.session.append('user/message', said, 'append');
          firstStep = false;
        }
        const toolNames: string[] = [];
        for (const spec of TOOLS.list()) {
          toolNames.push(spec.name);
        }
        this.session.append('request/header', {
            header: {
              'config': {
                'provider': config.baseUrl,
                'model': config.model,
                'reasoningEffort': config.effort
              },
              'tools': toolNames
            },
            reason: this.requestHeaderLogged ? 'change' : 'initial'
          });
        this.requestHeaderLogged = true;

        const text: string[] = [];
        const thought: string[] = [];
        const calls: ToolCall[] = [];
        let failure = '';
        const requestStart = Date.now();
        let firstDelta = 0;
        let roundUsage: Usage = emptyUsage();
        await this.transport(config, this.attachShots(this.session.messages()), {
          onText: (delta: string) => {
            if (firstDelta === 0) {
              firstDelta = Date.now();
            }
            text.push(delta);
            sink.onText(delta);
          },
          onThought: (delta: string) => {
            if (firstDelta === 0) {
              firstDelta = Date.now();
            }
            thought.push(delta);
            sink.onThought(delta);
          },
          onToolCall: (call: ToolCall) => {
            calls.push(call);
          },
          onUsage: (usage: Usage) => {
            roundUsage = usage;
          },
          onDone: () => {
          },
          onError: (message: string) => {
            failure = message;
          }
        }, this.abort);

        const assembled = text.join('');
        const reasoning = thought.join('');
        const requestEnd = Date.now();
        hilog.info(0x0000, 'hvoltide',
          'step done: text=%{public}d reasoning=%{public}d tools=%{public}d',
          assembled.length, reasoning.length, calls.length);

        if (failure.length > 0) {
          this.session.append('assistant/attempt', { turn: this.turn, step: this.step, stream: streamOf('text-chunks', assembled + reasoning, requestEnd) });
          for (const call of calls) {
            this.session.noteToolCall(call, Date.now());
            this.session.appendToolResult(call.id, 'error: 这一步请求失败，工具没有执行', true,
              Date.now());
          }
          this.session.append('step/end', { turn: this.turn, step: this.step });
          sink.onError(failure);
          closed = 'request-failed';
          break;
        }

        if (assembled.trim().length === 0 && reasoning.trim().length === 0 && calls.length === 0) {
          // 空回复不是一步：记一条 attempt 收尾。DSH 不重试。
          this.session.append('assistant/attempt', { turn: this.turn, step: this.step, stream: [] });
          this.session.append('step/end', { turn: this.turn, step: this.step });
          sink.onError('模型返回了空响应');
          closed = 'empty';
          break;
        }

        this.session.append('assistant/message', {
            turn: this.turn,
            step: this.step,
            message: assistantMessage(assembled, calls, reasoning),
            stream: streamOf('text-chunks', assembled, requestEnd),
            usage: roundUsage
          }, 'append');

        if (calls.length === 0) {
          this.session.append('step/end', { turn: this.turn, step: this.step });
          closed = 'done';
          break;
        }

        const batch = await runBatch(calls, (call: ToolCall) => this.invoke(call),
          this.session, sink, () => this.abort.cancelled, () => Date.now());
        this.session.append('step/end', { turn: this.turn, step: this.step });
        if (batch.cancelled) {
          closed = 'cancelled';
          break;
        }
      }
    } finally {
      if (closed.length === 0) {
        closed = 'done';
      }
      this.session.append('turn/end', { turn: this.turn, reason: turnEndReason(closed) });
      this.running = false;
      sink.onDone();
    }
  }

  // --- 压缩 ------------------------------------------------------------------------------------

  /** 当前 surface 的估算占用，对应 DSH 的 measurement.tokens。 */
  private contextTokens(): number {
    let total = 0;
    for (const seq of this.session.surfaceSeqs()) {
      const message = this.session.deriveEventMessage(seq);
      if (message !== undefined) {
        total += priceOfMessage(message);
      }
    }
    return total;
  }

  /** 消息预算 = 窗口容量 - 预留给回复的 token，对应 DSH 的 messageBudgetTokens。 */
  private messageBudgetTokens(): number {
    return this.session.contextWindow > this.session.reservedCompletionTokens
      ? this.session.contextWindow - this.session.reservedCompletionTokens : 0;
  }

  /** 占用越过消息预算就该压缩，判据与 dsh-compaction-basic 的 resolveCompactSpec 一致。 */
  private needsCompaction(): boolean {
    const budget = this.messageBudgetTokens();
    return budget > 0 && this.contextTokens() >= budget;
  }

  private async compactIfNeeded(config: LlmConfig): Promise<boolean> {
    if (!this.needsCompaction()) {
      return false;
    }
    return await this.runCompaction(config) !== null;
  }

  async compactNow(config: LlmConfig): Promise<CompactOutcome | null> {
    if (this.running) {
      return null;
    }
    return this.runCompaction(config);
  }

  /** 选出可替换的区间；没有安全的一段就返回 null。 */
  private selectRegion(): Region | null {
    const seqs: number[] = this.session.surfaceSeqs();
    if (seqs.length === 0) {
      return null;
    }
    const priced: Object[] = [];
    for (const seq of seqs) {
      const message = this.session.deriveEventMessage(seq);
      priced.push({ 'seq': seq, 'tokens': message === undefined ? 0 : priceOfMessage(message) });
    }
    const isSystemHead = (seq: number): boolean => {
      const message = this.session.deriveEventMessage(seq);
      return message !== undefined && message.role === 'system';
    };
    const balanced = (seq: number): boolean => this.toolPairsBalancedBefore(seq);
    return selectCompactableRange(seqs, priced as Object[] as PricedNode[], isSystemHead, balanced,
      this.session.reservedCompletionTokens);
  }

  /** 在 seq 之前，tool call 与 result 是否已经配对 —— 选区不能切开一对调用与结果。 */
  private toolPairsBalancedBefore(seq: number): boolean {
    const calls: Set<string> = new Set<string>();
    const results: Set<string> = new Set<string>();
    for (const event of this.session.all()) {
      if (event.seq >= seq) {
        break;
      }
      if (event.type === 'tool/call') {
        calls.add((event.data as Record<string, Object>)['callId'] as string);
      } else if (event.type === 'tool/result') {
        results.add((event.data as Record<string, Object>)['callId'] as string);
      }
    }
    for (const id of calls) {
      if (!results.has(id)) {
        return false;
      }
    }
    return true;
  }

  private async runCompaction(config: LlmConfig): Promise<CompactOutcome | null> {
    const region = this.selectRegion();
    if (region === null) {
      return null;
    }
    const at = Date.now();
    this.compactionId = 'cmp-' + String(at);
    const startEvent = this.session.append('compaction/start', { compactionId: this.compactionId, turn: Math.max(this.turn, 1) });
    const summary = await this.summarize(config, region);
    if (summary.trim().length === 0) {
      this.session.append('compaction/end', { compactionId: this.compactionId, turn: Math.max(this.turn, 1) });
      return null;
    }
    const before = this.contextTokens();
    const shadowed: number[] = [];
    for (const seq of this.session.surfaceSeqs()) {
      if (seq >= region.startSeq && seq <= region.endSeq) {
        shadowed.push(seq);
      }
    }
    let shadowedTokens = 0;
    for (const message of this.session.messagesInRange(region.startSeq, region.endSeq)) {
      shadowedTokens += priceOfMessage(message);
    }
    const summaryEvent = this.session.append('compaction/summary', {
        compactionId: this.compactionId,
        summary: summary,
        shadowedRange: { start: region.startSeq, end: region.endSeq },
        shadowedSeqs: shadowed,
        shadowedTokenCount: shadowedTokens
      });
    const sources: number[] = [startEvent.seq, summaryEvent.seq].concat(shadowed);
    this.session.append('user/message', userMessage('(compacted context)\n' + summary, []),
      { op: 'replace', startSeq: region.startSeq, endSeq: region.endSeq }, sources);
    this.session.append('compaction/end', { compactionId: this.compactionId, turn: Math.max(this.turn, 1) });
    const after = this.contextTokens();
    if (after >= before) {
      return null;
    }
    hilog.info(0x0000, 'hvoltide',
      'compacted seq %{public}d-%{public}d tokens=%{public}d', region.startSeq, region.endSeq, after);
    return { from: region.startSeq, to: region.endSeq, tokens: after };
  }

  /** 生成摘要的一次请求：重放系统提示与被替换的那段，再追加固定指令。 */
  private async summarize(config: LlmConfig, region: Region): Promise<string> {
    const messages: ChatMessage[] = [];
    let system = '';
    for (const seq of this.session.surfaceSeqs()) {
      const message = this.session.deriveEventMessage(seq);
      if (message !== undefined && message.role === 'system') {
        system = message.content;
      }
    }
    if (system.length > 0) {
      messages.push(systemMessage(system));
    }
    for (const message of this.session.messagesInRange(region.startSeq, region.endSeq)) {
      messages.push(message);
    }
    messages.push(runtimeMessage(COMPACTION_INSTRUCTION));
    const parts: string[] = [];
    const local: AbortFlag = new AbortFlag();
    let failure = '';
    await this.transport(config, messages, {
      onText: (delta: string) => {
        parts.push(delta);
      },
      onThought: (delta: string) => {
      },
      onToolCall: (call: ToolCall) => {
      },
      onUsage: (usage: Usage) => {
      },
      onDone: () => {
      },
      onError: (message: string) => {
        failure = message;
      }
    }, local);
    if (failure.length > 0) {
      hilog.warn(0x0000, 'hvoltide', 'compaction summary failed: %{public}s', failure);
      return '';
    }
    return parts.join('');
  }

  // --- 工具 ------------------------------------------------------------------------------------

  private async invoke(call: ToolCall): Promise<string> {
    const out: string = await dispatch(call, (name: string) => {
      const spec: ToolSpec | undefined = TOOLS.get(name);
      return spec === undefined ? undefined : { handler: spec.handler };
    });
    // 截图工具只返回路径，模型看不到文件；落盘成功就把它收起来，下一次请求带上。
    if (call.name === 'screenshot' && out.indexOf('code=0') >= 0) {
      this.collectShot();
    }
    return out;
  }

  /** 把这一轮拍下的截图带进下一次请求。 */
  private attachShots(messages: ChatMessage[]): ChatMessage[] {
    if (this.pendingShots.length === 0) {
      return messages;
    }
    const shots: string[] = this.pendingShots.slice();
    this.pendingShots = [];
    messages.push({
      id: -1, role: 'user', source: 'runtime', content: '(截图见附图)',
      reasoning: '', context: '', images: shots, toolCalls: [], toolCallId: ''
    });
    return messages;
  }

  /** 截图落盘后读成 data URL。读不到不算失败。 */
  private collectShot(): void {
    try {
      const path: string = getContext().filesDir + '/screenshot.jpeg';
      const stat = fs.statSync(path);
      if (stat.size <= 0 || stat.size > 6 * 1024 * 1024) {
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const b64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(buf));
      this.pendingShots.push('data:image/jpeg;base64,' + b64);
    } catch (e) {
    }
  }
}

/** turn/end 的 reason，取值照 dsh-session 的 TurnEndReason。 */
function turnEndReason(closed: string): Object {
  if (closed === 'done') {
    return { kind: 'completed' } as Object;
  }
  if (closed === 'cancelled') {
    return { kind: 'aborted', reason: 'user' } as Object;
  }
  if (closed === 'empty') {
    return { kind: 'blocked' } as Object;
  }
  return { kind: 'error', error: { message: closed, code: 'UNKNOWN' } } as Object;
}

/** 一步的输出流记录，形状照 DSH 的 AssistantStreamRecord：同一类增量压成一条。 */
function streamOf(type: string, text: string, time: number): Object[] {
  if (text.length === 0) {
    return [];
  }
  return [{ 'type': type, 'time0': time, 'index': 0, 'dt': [0], 'texts': [text] }];
}

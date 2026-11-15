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
import { prepareRequest } from './Wire';
import { dispatch } from './Dispatch';
import { LlmConfig } from './Settings';
import { fetchContextWindow } from './Models';
import { ChatMessage, ToolCall, Usage, assistantMessage, emptyUsage, runtimeMessage, systemMessage, userMessage } from './Types';
import { Session, priceOfMessage } from '../session/Session';
import { SessionStats } from '../session/Stats';
import { selectCompactableRange } from '../session/Compact';
import type { CompactAttempt } from '../session/Compact';
import { compileCheckpoint } from '../session/Vcc';
import type { Checkpoint } from '../session/Vcc';
import type { CompactOutcome, PricedNode, Region } from '../session/Compact';
import { recallEvents } from './Recall';
import { APPROVAL } from '../Approval';
import { snapshotAnnotate, snapshotCommit } from 'libnavi.so';

export type Transport = (config: LlmConfig, messages: ChatMessage[], sink: StreamSink,
  abort: AbortFlag) => Promise<void>;


/** 触发线：窗口的 50%（dsh-compaction-instant 的 thresholdRatio）。 */
const COMPACT_THRESHOLD_RATIO: number = 0.5;

/** 尾部原样保留：窗口的 5%（instant 的 retainRatio）。 */
const COMPACT_RETAIN_RATIO: number = 0.05;

export interface LoopSink {
  onText: (delta: string) => void;
  onThought: (delta: string) => void;
  onToolStart: (call: ToolCall) => void;
  onToolResult: (callId: string, text: string) => void;
  onError: (message: string) => void;
  onDone: () => void;
}


/** 技能目录的标记：目录拼在系统提示里，读回时靠它拆开。 */
const CATALOG_TAG: string = '<!-- skill-catalog -->';

export class ChatSession {
  private session: Session = new Session('chat', '');

  /**
   * 启动时先把窗口问出来。
   *
   * 状态栏的占用百分比要一个分母；把它推后到第一条消息，等于进程刚起来那段时间整段不显示
   * （`statPressure` 为 0 时那一块根本不渲染）。
   */
  async warmContextWindow(config: LlmConfig): Promise<void> {
    await this.applyContextWindow(config);
  }

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
  /** 当前项目根，由会话层给出；空串表示没有打开项目，此步不落快照。 */
  private projectRootOf: () => string = () => '';
  /** 上一次落盘还没回来时不再排新的：每步都排会在工作线程里堆任务。 */
  private snapshotBusy: boolean = false;
  /** 本步用到的工具名与改动文件数，等这一步结束再补进快照的 message。 */
  private stepTool: string = '';
  private stepFiles: number = 0;
  /** 本步是否落了快照；没落就没有可补的 commit。 */
  private stepSnapshot: boolean = false;

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

  /** 会话层每次发送前把当前项目根交进来，快照才知道该记哪个工作树。 */
  setProjectRoot(read: () => string): void {
    this.projectRootOf = read;
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

  /**
   * 窗口取配置值；配置没写就问端点（/models），答案记下来，一次会话只问一次。
   *
   * 两边都没有时保持 0：0 表示未知，压缩与百分比据此显示「未知」，而不是拿一个编出来的分母
   * 说话。这里原先回退到 1000000，触发线随之落在 500000 tokens——永远到不了，自动压缩等于
   * 没接，状态栏的百分比也一直在用一个不存在的窗口做除法。
   */
  private async applyContextWindow(config: LlmConfig): Promise<void> {
    if (config.contextWindow > 0) {
      this.setContextWindow(config.contextWindow);
      return;
    }
    if (this.windowProbe === undefined) {
      this.windowProbe = await fetchContextWindow(config);
      // 读数先落在日志里：窗口决定触发线与状态栏的分母，它是不是 0 关系到压缩有没有接上。
      hilog.info(0x0000, 'hvoltide', 'context window from endpoint: %{public}d', this.windowProbe);
    }
    this.setContextWindow(this.windowProbe);
  }

  /** 端点上读到的窗口；undefined 表示还没问过，0 表示问过但没有答案。 */
  private windowProbe: number | undefined = undefined;

  async send(config: LlmConfig, userText: string, context: string, images: string[],
    sink: LoopSink): Promise<void> {
    if (this.running) {
      sink.onError('a turn is already running');
      return;
    }
    this.running = true;
    await this.applyContextWindow(config);
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
        this.snapshotStep();
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
        let finishReason = '';
        const outbound = prepareRequest(this.session.messages());
        // 违约就是服务端会用 400 拒掉整轮的那种状态；先在这里说清楚是哪个调用。
        if (outbound.broken.length > 0) {
          hilog.warn(0x0000, 'hvoltide', 'request would break the tool protocol: %{public}s',
            outbound.broken.join(','));
        }
        await this.transport(config, this.attachShots(outbound.messages), {
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
          onFinish: (reason: string) => {
            finishReason = reason;
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
        // tok/s 只算生成区间：从第一个增量到最后一块，不含排队与首个 token 之前的等待。
        const generateFrom: number = firstDelta > 0 ? firstDelta : requestStart;
        roundUsage.elapsedMs = requestEnd > generateFrom ? requestEnd - generateFrom : 0;
        hilog.info(0x0000, 'hvoltide',
          'step done: text=%{public}d reasoning=%{public}d tools=%{public}d finish=%{public}s',
          assembled.length, reasoning.length, calls.length, finishReason);
        // 被长度上限截断时，回复看起来和「模型没说话」一样；把原因记进日志才有据可查。
        if (finishReason === 'length') {
          hilog.warn(0x0000, 'hvoltide', 'step ended on the length limit (budget ran out)');
        }

        if (failure.length > 0) {
          this.session.append('assistant/attempt', { turn: this.turn, step: this.step, stream: streamOf('text-chunks', assembled + reasoning, requestEnd) });
          for (const call of calls) {
            this.session.noteToolCall(call, Date.now());
            this.session.appendToolResult(call.id, 'error: 这一步请求失败，工具没有执行', true,
              Date.now());
          }
          this.annotateStep();
          this.session.append('step/end', { turn: this.turn, step: this.step });
          sink.onError(failure);
          closed = 'request-failed';
          break;
        }

        if (assembled.trim().length === 0 && reasoning.trim().length === 0 && calls.length === 0) {
          // 空回复不是一步：记一条 attempt 收尾。DSH 不重试。
          this.session.append('assistant/attempt', { turn: this.turn, step: this.step, stream: [] });
          this.annotateStep();
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
          this.annotateStep();
          this.session.append('step/end', { turn: this.turn, step: this.step });
          closed = 'done';
          break;
        }

        const batch = await runBatch(calls, (call: ToolCall) => this.invoke(call),
          this.session, sink, () => this.abort.cancelled, () => Date.now());
        this.annotateStep();
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

  /**
   * 消息预算 = 窗口容量 - 预留给回复的 token，对应 dsh-compaction-basic 的 messageBudgetTokens。
   * 触发线取预算的 50%（设计文档要求），不是「窗口快满才动」。
   */
  private messageBudgetTokens(): number {
    return this.session.contextWindow > this.session.reservedCompletionTokens
      ? this.session.contextWindow - this.session.reservedCompletionTokens : 0;
  }

  /** 触发线 = contextWindow × 0.5（dsh-compaction-instant 的 thresholdRatio）。 */
  private pressureBudgetTokens(): number {
    const window: number = this.session.contextWindow;
    return window > 0 ? Math.floor(window * COMPACT_THRESHOLD_RATIO) : 0;
  }

  /** 尾部原样保留 = contextWindow × 0.05（instant 的 retainRatio）。 */
  private retainBudgetTokens(): number {
    const window: number = this.session.contextWindow;
    return window > 0 ? Math.floor(window * COMPACT_RETAIN_RATIO) : 0;
  }

  private needsCompaction(): boolean {
    const budget = this.pressureBudgetTokens();
    return budget > 0 && this.contextTokens() >= budget;
  }

  private async compactIfNeeded(config: LlmConfig): Promise<boolean> {
    if (!this.needsCompaction()) {
      return false;
    }
    const attempt = await this.runCompaction(config);
    return attempt.outcome !== null;
  }

  /** 手动压缩：回合在跑时不再吞掉请求，而是回报原因（界面据此显示不同文案）。 */
  async compactNow(config: LlmConfig): Promise<CompactAttempt> {
    if (this.running) {
      return { outcome: null, stop: 'busy' };
    }
    // 手动压缩也要有窗口：否则触发线算不出来，界面只能显示「无安全区间」。
    await this.applyContextWindow(config);
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
      this.retainBudgetTokens());
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

  private async runCompaction(config: LlmConfig): Promise<CompactAttempt> {
    // 窗口未知时保留预算也是 0，selectRegion 会把除末条以外的历史全选进去。宁可什么都不做。
    if (this.session.contextWindow <= 0) {
      return { outcome: null, stop: 'unknown-window' };
    }
    const region = this.selectRegion();
    if (region === null) {
      return { outcome: null, stop: 'no-region' };
    }
    const at = Date.now();
    this.compactionId = 'cmp-' + String(at);
    const startEvent = this.session.append('compaction/start', { compactionId: this.compactionId, turn: Math.max(this.turn, 1) });
    const summary: string = this.compileRegion(region);
    if (summary.trim().length === 0) {
      this.session.append('compaction/end', { compactionId: this.compactionId, turn: Math.max(this.turn, 1) });
      return { outcome: null, stop: 'empty-summary' };
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
    // checkpoint 是压缩的唯一表示：一条 user/message，来源标 `checkpoint`，首行写明它替代了哪一段。
    // 界面在它落在日志里的位置画一行，不从 compaction/summary 反推位置——反推出来的位置没有归属，
    // 只能排到最下方，看上去像刚刚发生的事。
    const checkpoint = userMessage(
      checkpointText(region.startSeq, region.endSeq, shadowedTokens, summary), []);
    checkpoint.source = 'checkpoint';
    this.session.append('user/message', checkpoint,
      { op: 'replace', startSeq: region.startSeq, endSeq: region.endSeq }, sources);
    this.session.append('compaction/end', { compactionId: this.compactionId, turn: Math.max(this.turn, 1) });
    const after = this.contextTokens();
    if (after >= before) {
      hilog.warn(0x0000, 'hvoltide',
        'compaction did not shrink: before=%{public}d after=%{public}d', before, after);
      return { outcome: null, stop: 'not-smaller' };
    }
    hilog.info(0x0000, 'hvoltide',
      'compacted seq %{public}d-%{public}d tokens=%{public}d', region.startSeq, region.endSeq, after);
    return { outcome: { from: region.startSeq, to: region.endSeq, tokens: after }, stop: null };
  }

  /**
   * 把选中的区间编译成 checkpoint 文本。
   *
   * 这里不调模型：VCC 的路径是确定性切片——工具调用压成一行并带 `-> result N` 指针，
   * 工具结果不抄正文，reasoning 不进台账。摘要式压缩会把路径与命令改写成「差不多」的说法，
   * 也会多花一次推理，这条路径不用。
   */
  private compileRegion(region: Region): string {
    const seqs: number[] = [];
    const messages: ChatMessage[] = [];
    const resultSeqs: Map<string, number> = new Map<string, number>();
    for (const seq of this.session.surfaceSeqs()) {
      if (seq >= region.startSeq && seq <= region.endSeq) {
        const message: ChatMessage | undefined = this.session.deriveEventMessage(seq);
        if (message !== undefined) {
          seqs.push(seq);
          messages.push(message);
          if (message.role === 'tool' && message.toolCallId.length > 0) {
            resultSeqs.set(message.toolCallId, seq);
          }
        }
      }
    }
    const checkpoint: Checkpoint = compileCheckpoint({
      seqs: seqs, messages: messages, resultSeqs: resultSeqs,
      turns: Math.max(this.turn, 1)
    });
    return checkpoint.text;
  }

  // --- 工具 ------------------------------------------------------------------------------------

  private async invoke(call: ToolCall): Promise<string> {
    // 一个步骤里可能调多个工具：快照 message 的 tool 段记第一个，files 段数改动次数。
    if (this.stepTool.length === 0) {
      this.stepTool = call.name;
    }
    const out: string = await dispatch(call, (name: string) => {
      const spec: ToolSpec | undefined = TOOLS.get(name);
      if (spec === undefined) {
        return undefined;
      }
      return { handler: spec.handler, approval: spec.approval };
    }, (tool: string, detail: string): Promise<boolean> => {
      return APPROVAL.request(tool, detail);
    });
    // 改动文件的工具只有这几个；数的是调用次数，不是真正落盘的文件数——
    // apply_patch 一次可改多个文件，精确计数要解析结果，等有步骤真的依赖这个数字再说。
    const mutating: string[] = ['write', 'edit', 'apply_patch'];
    if (mutating.indexOf(call.name) >= 0 && out.indexOf('error') !== 0) {
      this.stepFiles += 1;
    }
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
  /**
   * 每步落一个快照。失败不中断这一步：快照是回退用的旁路能力，它坏了不该让对话停下，
   * 但要留下一条日志，因为「以为有快照其实没有」比「没有快照」更危险。
   */
  private snapshotStep(): void {
    const root = this.projectRootOf();
    if (root.length === 0) {
      return;
    }
    const cut = root.lastIndexOf('/');
    const name = cut >= 0 ? root.substring(cut + 1) : root;
    // libgit2 的 init 只建 .git 自身，父目录必须先存在，否则报 No such file or directory。
    const base = getContext().filesDir + '/snapshots';
    const snapshots = base + '/' + name;
    this.stepTool = '';
    this.stepFiles = 0;
    this.stepSnapshot = false;
    try {
      if (!fs.accessSync(base)) {
        fs.mkdirSync(base);
      }
      if (!fs.accessSync(snapshots)) {
        fs.mkdirSync(snapshots);
      }
    } catch (e) {
      hilog.warn(0x0000, 'hvoltide', 'snapshot dir failed: %{public}s', (e as Error).message);
      return;
    }
    // 不等它：落快照是旁路能力，等它就把这一步的响应拖住了。
    if (this.snapshotBusy) {
      return;
    }
    this.snapshotBusy = true;
    this.stepSnapshot = true;
    snapshotCommit(snapshots, root, 'step=' + this.step).then((out: string) => {
      if (out.indexOf('"error"') >= 0) {
        this.stepSnapshot = false;
        hilog.warn(0x0000, 'hvoltide', 'snapshot skipped: %{public}s', out);
      }
    }).catch((e: Error) => {
      this.stepSnapshot = false;
      hilog.warn(0x0000, 'hvoltide', 'snapshot rejected: %{public}s', e.message);
    }).finally(() => {
      this.snapshotBusy = false;
    });
  }

  /**
   * 步骤结束时把 tool 与 files 补进这一条快照的 message。
   *
   * 快照落在写文件之前，那时这两个值还不知道；commit 的树不动，只换 message，所以补写不会
   * 改变回退能恢复到的内容。
   */
  private annotateStep(): void {
    if (!this.stepSnapshot) {
      return;
    }
    const root = this.projectRootOf();
    if (root.length === 0) {
      return;
    }
    const cut = root.lastIndexOf('/');
    const name = cut >= 0 ? root.substring(cut + 1) : root;
    const snapshots = getContext().filesDir + '/snapshots/' + name;
    const tool = this.stepTool.length === 0 ? 'none' : this.stepTool;
    const message = 'step=' + this.step + '|tool=' + tool + '|files=' + this.stepFiles;
    snapshotAnnotate(snapshots, root, message).catch((e: Error) => {
      hilog.warn(0x0000, 'hvoltide', 'snapshot annotate failed: %{public}s', e.message);
    });
    this.stepSnapshot = false;
  }

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

/**
 * checkpoint 的正文：首行说明它替代了哪一段、多大，正文跟在后面空一行。
 *
 * 这一行跟着消息一起落盘，所以界面不需要另外的记账事件就能画出它——位置就是消息的位置。
 */
function checkpointText(from: number, to: number, tokens: number, body: string): string {
  const head = '已压缩 seq ' + String(from) + '-' + String(to) + ' · 约 ' + String(tokens) + ' tokens';
  const trimmed = body.trim();
  return trimmed.length === 0 ? head : head + '\n\n' + trimmed;
}

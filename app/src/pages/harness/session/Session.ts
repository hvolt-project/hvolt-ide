// 一段会话：一条 append-only 的事件日志，加上从它派生出来的投影。
//
// 结构照 @deepseek-ai/dsh-session：
//   事件的判别联合与 surface 元数据 —— ./Events.ts（逐条对应 dsh-session/types.d.ts）
//   surface 的追加与替换语义       —— ./Surface.ts（对应 surface.js）
//   落盘的一行一事件               —— ./Log.ts（对应 persistence-jsonl）
//   append 分配 seq/time           —— dsh-session/lib/index.js:1518-1539
//
// 一处必须说清的估算：上下文占用按字符密度计价（estimateContent），因为本 app 没有
// 引入 DSH 的 conversation meter。这个数字只用于触发压缩，不参与任何对外结论。

import type { ChatMessage, ToolCall, Usage } from '../loop/Types';
import { emptyStats, foldStats, SessionStats } from './Stats';
import { assistantMessage, runtimeMessage, systemMessage, toolMessage, userMessage } from '../loop/Types';
import type { SessionEvent, SessionEventType, SessionSeq, SurfaceOp } from './Events';
import { SessionLog } from './Log';
import { applySurface, emptySurface, isAppendSurfaceEvent } from './Surface';
import type { SurfaceState } from './Surface';
import { selectCompactableRange } from './Compact';
import type { CompactOutcome, PricedNode, Region } from './Compact';

/* 固定密度估算：两个常量与块级算式照 dsh-token-meter/lib/index.js 的
 *  CHARS_PER_TOKEN / BLOCK_OVERHEAD / estimateContent，保证同一段内容两边算出一致的数字。 */
const CHARS_PER_TOKEN = 4;
const BLOCK_OVERHEAD = 4;

/** 一个内容块的估算价格，对应 dsh-token-meter 的 estimateContent。 */
function estimateContent(kind: string, text: string): number {
  if (text.length === 0) {
    return 0;
  }
  return Math.ceil(text.length / CHARS_PER_TOKEN) + BLOCK_OVERHEAD;
}

/** 一条消息的价格：文本、推理、工具调用各算一块，每块都带结构开销。 */
export function priceOfMessage(message: ChatMessage): number {
  let tokens = estimateContent('text', message.content);
  tokens += estimateContent('reasoning', message.reasoning);
  for (const call of message.toolCalls) {
    tokens += Math.ceil(call.name.length / CHARS_PER_TOKEN)
      + Math.ceil(call.argumentsJson.length / CHARS_PER_TOKEN) + BLOCK_OVERHEAD;
  }
  return tokens;
}

export class Session {
  readonly id: string;
  private readonly log: SessionLog;
  private surfaceState: SurfaceState = emptySurface();
  private header: Object | undefined = undefined;
  private events: SessionEvent[] = [];
  contextWindow: number = 0;
  reservedCompletionTokens: number = 8192;
  // 当前轮与步，由 turn/start、step/start 事件带入，工具事件照抄。
  private turnNow: number = 0;
  private stepNow: number = 0;
  private compactionStartSeq: number = -1;
  private compactionId: string = '';

  constructor(id: string = 'local', path: string = '') {
    this.id = id;
    this.log = new SessionLog(path);
    // 必须取副本：Log.append 会把事件 push 进它自己的 cache，若这里持同一数组，
    // 同一条事件会被记两次，seq 只占偶数，下次载入因序号重复整份拒绝。
    this.events = this.log.events().slice();
    this.rebuild();
  }

  /** 磁盘路径为空时这个会话只在内存里（测试与未落盘的会话）。 */
  private rebuild(): void {
    let state = emptySurface();
    let header: Object | undefined = undefined;
    let turn = 0;
    for (const event of this.events) {
      if (event === undefined || event === null) {
        continue;
      }
      // 旧日志里可能缺 data（更早的写法把字段摊在顶层），读回时不能假设它在。
      const data: Record<string, Object> =
        event.data === undefined || event.data === null
          ? {} as Record<string, Object> : event.data as Record<string, Object>;
      const safe: SessionEvent = {
        type: event.type,
        seq: event.seq,
        time: event.time === undefined ? 0 : event.time,
        data: data,
        surfaceOp: event.surfaceOp,
        sourceEventSeqs: event.sourceEventSeqs
      };
      state = applySurface(state, safe);
      this.trackTurn(safe);
      if (event.type === 'request/header') {
        header = data as Object;
      }
    }
    this.surfaceState = state;
    this.header = header;
  }

  // --- 日志 ------------------------------------------------------------------------------------

  /**
  * 从一份 JSONL 文本恢复。要么完整载入，要么拒绝：
  * 跳过一行会让内存事件数少于文件行数，新事件占用旧序号，下次保存把历史再写一遍。
  * @returns 是否完整载入。
  */
  load(text: string): boolean {
    const restored: SessionEvent[] = [];
    const rows = text.split('\n');
    for (let index = 0; index < rows.length; index++) {
      const trimmed = rows[index].trim();
      if (trimmed.length === 0) {
        continue;
      }
      let event: SessionEvent;
      try {
        event = JSON.parse(trimmed) as SessionEvent;
      } catch (error) {
        return false;
      }
      if (typeof event.seq !== 'number' || typeof event.type !== 'string' ||
        event.seq !== restored.length) {
        return false;
      }
      restored.push(event);
    }
    this.events = restored;
    this.log.seed(restored);
    this.rebuild();
    return true;
  }

  /** 状态栏用的统计，从事件流折叠。 */
  stats(): SessionStats {
    if (!this.log.isLoaded()) {
      return emptyStats();
    }
    return foldStats(this.events, this.contextWindow);
  }

  dump(): string {
    return serialize(this.events, 0);
  }

  /** 只序列化 index 之后追加的部分。 */
  dumpSince(index: number): string {
    return serialize(this.events, index);
  }

  eventCount(): number {
    return this.events.length;
  }

  /**
   * 磁盘上已有的行数（含坏行）。续写的起点必须用它而不是 eventCount()：
   * 坏行没有进内存，用事件数当起点会把已经写过的部分再写一遍。
   */
  loadedLineCount(): number {
    return this.log.lineCount();
  }

  all(): SessionEvent[] {
    return this.events;
  }

  /** 最近一次 request/header 记录的调用配置与工具表，对应 DSH 的 requestHeader()。 */
  requestHeader(): Object | undefined {
    return this.header;
  }

  /**
   * 追加一条事件：先落盘，再折进 surface 与内存列表。落盘失败则内存不动。
   * 参数形状照 DSH 的 Session.append(type, data, opts)。
   */
  append(type: SessionEventType, data: Object, surfaceOp?: SurfaceOp,
    sourceEventSeqs?: SessionSeq[]): SessionEvent {
    const event = this.log.append(type, data, surfaceOp, sourceEventSeqs);
    this.events.push(event);
    this.surfaceState = applySurface(this.surfaceState, event);
    if (event.type === 'request/header') {
      this.header = event.data as Object;
    }
    this.trackTurn(event);
    return event;
  }

  /** 事件的 turn/step 由 turn/start、step/start 带进来；工具事件要照抄当时的编号。 */
  private trackTurn(event: SessionEvent): void {
    const data = event.data as Record<string, Object>;
    if (event.type === 'turn/start') {
      this.turnNow = numberOrZero(data['turn']);
    } else if (event.type === 'step/start') {
      this.stepNow = numberOrZero(data['step']);
    }
  }

  /**
   * 工具调用在它开跑**之前**写下：事后才能区分「根本没开始」与「开始了但结果未知」。
   * 这是 ToolBatch 的 BatchRecorder 约定，时间由日志自己盖，`at` 只为接口对称。
   */
  noteToolCall(call: ToolCall, at: number): void {
    this.append('tool/call', {
      turn: this.turnNow,
      step: this.stepNow,
      callId: call.id,
      name: call.name,
      arguments: call.argumentsJson
    });
  }

  /** 工具的结果按 surface 事件落盘，模型下一次请求就在消息里看到它。 */
  appendToolResult(callId: string, text: string, isError: boolean, at: number): void {
    this.append('tool/result', {
      turn: this.turnNow,
      step: this.stepNow,
      message: toolMessage(callId, text)
    }, 'append');
  }

  // --- 投影 ------------------------------------------------------------------------------------

  /** 模型可见的节点 seq。 */
  surface(): SurfaceState {
    return this.surfaceState;
  }

  private bySeq(): Map<number, SessionEvent> {
    const map: Map<number, SessionEvent> = new Map<number, SessionEvent>();
    for (const event of this.events) {
      map.set(event.seq, event);
    }
    return map;
  }

  /** surface 上的节点 seq，按顺序 —— 与 DSH 的 session.surface.nodes 同义。 */
  surfaceSeqs(): SessionSeq[] {
    return this.surfaceState.nodes;
  }

  /** 某个节点对应的消息；不是消息类事件就是 undefined。 */
  deriveEventMessage(seq: SessionSeq): ChatMessage | undefined {
    for (const event of this.events) {
      if (event.seq === seq) {
        return messageOf(event);
      }
    }
    return undefined;
  }

  /** 模型现在会收到的消息序列。 */
  messages(): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (const seq of this.surfaceSeqs()) {
      const message = this.deriveEventMessage(seq);
      if (message !== undefined) {
        out.push(message);
      }
    }
    return out;
  }

  /**
   * 展示用的对话：只取 append 进 surface 的事件（替换副本只给模型看，不回到人的视野），
   * 系统提示不进对话；运行时注入保留，由显示层标成可折叠的一行。
   */
  transcript(base: number): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (const event of this.events) {
      if (event.seq < base || !isAppendSurfaceEvent(event)) {
        continue;
      }
      const message = messageOf(event);
      if (message === undefined || message.role === 'system') {
        continue;
      }
      out.push(message);
    }
    return out;
  }

  /** 某段 seq 区间内的消息，用于压缩前重放被替换的前缀。 */
  messagesInRange(startSeq: number, endSeq: number): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (const event of this.events) {
      if (event.seq < startSeq || event.seq > endSeq) {
        continue;
      }
      const message = messageOf(event);
      if (message !== undefined) {
        out.push(message);
      }
    }
    return out;
  }

  // --- 提示词节点 ------------------------------------------------------------------------------


  /** 在 seq 之前，tool call 与 result 是否已经配对。 */
}

/**
 * 从磁盘读回的消息可能来自更早的日志格式，字段不全。补齐后再交给上层，
 * 否则显示层读 reasoning.length 这类字段时会直接抛异常。
 */
/**
 * 每行一个事件，末尾必须带换行：追加写会把两次 dump 的内容首尾相接，
 * 少了这个换行，上一批的最后一条与下一批的第一条会粘成一行，那一行随即解析失败。
 */
function serialize(events: SessionEvent[], from: number): string {
  let out = '';
  for (let i = from; i < events.length; i++) {
    out += JSON.stringify(events[i]) + '\n';
  }
  return out;
}

function normalizeMessage(raw: Object): ChatMessage {
  const item = raw as Record<string, Object>;
  const pick = (key: string, fallback: Object): Object =>
    item[key] === undefined || item[key] === null ? fallback : item[key];
  return {
    id: pick('id', 0) as number,
    role: pick('role', 'user') as string,
    source: pick('source', 'human') as string,
    content: pick('content', '') as string,
    reasoning: pick('reasoning', '') as string,
    context: pick('context', '') as string,
    images: pick('images', []) as string[],
    toolCalls: pick('toolCalls', []) as ToolCall[],
    toolCallId: pick('toolCallId', '') as string
  } as ChatMessage;
}

/** 从一个事件取出它的消息；非消息类事件返回 undefined。 */
function messageOf(event: SessionEvent): ChatMessage | undefined {
  const data = event.data as Record<string, Object>;
  switch (event.type) {
    case 'system/message':
      return normalizeMessage(data['message']);
    case 'user/message':
      return normalizeMessage(event.data);
    case 'developer/message':
      return normalizeMessage(data['message']);
    case 'assistant/message':
      return normalizeMessage(data['message']);
    case 'tool/result':
      return normalizeMessage(data['message']);
    case 'compaction/summary':
      return normalizeMessage(data['message']);
    default:
      return undefined;
  }
}
/** 事件里的编号可能是缺失或非数字，按 0 处理，免得把 NaN 写进日志。 */
function numberOrZero(value: Object | undefined): number {
  return typeof value === 'number' ? value as number : 0;
}

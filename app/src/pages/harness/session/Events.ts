// 会话事件模型。逐条照 @deepseek-ai/dsh-session 的 types.d.ts 重建：
//   SurfaceEventType / SurfaceOp / SurfaceIntent   —— types.d.ts:440-490
//   TurnEndReasonMap 七分支                         —— types.d.ts:166-210
//   SessionEvent<T> 的 envelope                     —— types.d.ts:487-515
//   append 的 seq/time 分配                         —— dsh-session/lib/index.js:1518-1539
//
// 与 DSH 唯一的差别：SessionEventMap 只收本 app 会写的类型，DSH 的 approval/*、team/*、
// tool-workflow/* 等不在此处。

import type { ChatMessage, Usage } from '../loop/Types.ts';

/** 单调递增的会话内序号。 */
export type SessionSeq = number;

/** 产生模型可见消息的事件类型 —— 只有这些事件带 surface 元数据。 */
export type SurfaceEventType =
  'system/message' | 'developer/message' | 'user/message' | 'assistant/message' | 'tool/result';

/**
 * 事件如何进入有序 surface：
 * - 'append'：加到尾部
 * - { op: 'replace', startSeq, endSeq }：用这个节点替换 startSeq..endSeq（含两端）的当前 surface 节点，
 *   startSeq === endSeq 表示替换单个节点；被遮蔽的节点必须全部列进 sourceEventSeqs
 */
export type SurfaceOp = 'append' | {
  op: 'replace';
  startSeq: SessionSeq;
  endSeq: SessionSeq;
};

/** 消息类事件的落位方式与所引用的来源事件。 */
export type SurfaceIntent<T extends SurfaceEventType = SurfaceEventType> = {
  surfaceOp: SurfaceOp;
} & (T extends 'assistant/message' ? {
  sourceEventSeqs?: never;
} : {
  sourceEventSeqs?: SessionSeq[];
});

/** 中止原因。 */
export type TurnEndCancelCause = 'user' | 'system' | 'timeout' | 'shutdown';

/** 结构化失败。 */
export interface LlmFailure {
  message: string;
  code: string;
}

/** 回合结束原因，七个分支。 */
export interface TurnEndReasonMap {
  completed: { kind: 'completed' };
  aborted: { kind: 'aborted'; reason: TurnEndCancelCause };
  blocked: { kind: 'blocked' };
  error: { kind: 'error'; error: LlmFailure };
  'max-tokens': { kind: 'max-tokens' };
  interrupted: { kind: 'interrupted' };
  forked: { kind: 'forked' };
}

export type TurnEndReason = TurnEndReasonMap[keyof TurnEndReasonMap];

/**
 * 模型流的一段，形状照 dsh-llm/lib/types/assistant-stream.d.ts:16：
 * 同一类增量压成一条记录，time0 是首块时间，dt 是相邻块的毫秒差，texts 是块内容。
 */
export interface AssistantStreamRecord {
  type: string;
  time0: number;
  index: number;
  dt: number[];
  texts: string[];
}

/** 事件数据体，字段名与语义逐条照 SessionEventMap。 */
export interface SessionEventMap {
  'turn/start': { turn: number };
  'turn/end': { turn: number; reason: TurnEndReason };
  'step/start': { turn: number; step: number };
  'step/end': { turn: number; step: number };
  'user/message': ChatMessage;
  'developer/message': { turn: number; step: number; message: ChatMessage; headerSeq?: SessionSeq };
  'system/message': { turn: number; step: number; message: ChatMessage };
  'assistant/message': {
    turn: number;
    step: number;
    message: ChatMessage;
    stream: AssistantStreamRecord[];
    usage?: Usage;
    interrupted?: true;
  };
  'assistant/attempt': { turn: number; step: number; stream: AssistantStreamRecord[] };
  'tool/call': { turn: number; step: number; callId: string; name: string; arguments: string };
  'tool/result': { turn: number; step: number; message: ChatMessage };
  'request/header': { header: Object; reason: 'initial' | 'resume' | 'change' | 'series'; startsSeries?: true };
  'request/context': { turn: number; step: number };
  'compaction/start': { compactionId: string; turn: number };
  'compaction/summary': {
    compactionId: string;
    summary: string;
    shadowedRange: { start: SessionSeq; end: SessionSeq };
    shadowedSeqs: SessionSeq[];
    shadowedTokenCount: number;
  };
  'compaction/end': { compactionId: string; turn: number };
}

export type SessionEventType = keyof SessionEventMap;

/**
 * 本 build 认识的事件类型。读回一份日志时，类型不在这里、又没有 ignorable 标记的事件
 * 必须让整份会话重建失败 —— 静默跳过一个会改变其余事件的解释方式。
 * 与 dsh-session 的 KNOWN_SESSION_EVENT_TYPES 同一语义。
 */
export const KNOWN_EVENT_TYPES: Set<string> = new Set<string>([
  'turn/start', 'turn/end', 'step/start', 'step/end',
  'user/message', 'developer/message', 'system/message', 'assistant/message', 'assistant/attempt',
  'tool/call', 'tool/result', 'request/header', 'request/context',
  'compaction/start', 'compaction/summary', 'compaction/end'
]);

/** 事件类型常量，供按类型比较的调用方使用。 */
export const SYSTEM_MESSAGE = 'system/message';
export const USER_MESSAGE = 'user/message';
export const ASSISTANT_MESSAGE = 'assistant/message';
export const TOOL_RESULT = 'tool/result';

/**
 * 日志里的一条，不可变。
 * 语义与 DSH 的 SessionEvent 一致（type/seq/time/data/ignorable，插入 surface 时带 surfaceOp 与
 * sourceEventSeqs），但写成普通 interface 而不是映射类型：ArkTS 不支持 { [K in T]: ... }[T]。
 */
export interface SessionEvent {
  type: SessionEventType;
  /** 会话内单调序号。 */
  seq: SessionSeq;
  /** Unix epoch 毫秒。 */
  time: number;
  data: Object;
  /** 读端不认这个 type 时可以安全跳过；缺省表示必需。 */
  surfaceOp?: SurfaceOp;
  sourceEventSeqs?: SessionSeq[];
  ignorable?: true;
}

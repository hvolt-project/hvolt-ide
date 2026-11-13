// surface：模型可见的有序视图。append-only 的日志是唯一真相，surface 只是它的投影。
//
// 逐条照 dsh-session/lib/types/surface.js 重建：
//   SURFACE_EVENT_TYPES、isSurfaceEvent/isAppendSurfaceEvent/isReplacementSurfaceEvent  —— surface.js:14-61
//   replacementRange 的存在性/顺序校验与错误文案                                    —— surface.js:309-326
//   sourceEventSeqs 必须覆盖全部被遮蔽节点                                          —— surface.js:259-261
//   replace 的 startSeq/endSeq 必须引用更早的事件                                    —— surface.js:300-306

import type { SessionEvent, SessionSeq } from './Events';

/** 能进入模型可见 surface 的事件类型，运行时版本。 */
export const SURFACE_EVENT_TYPES: Set<string> = new Set<string>([
  'system/message',
  'developer/message',
  'user/message',
  'assistant/message',
  'tool/result',
]);

/** 这个类型的事件是否可能进入 surface。 */
export function isSurfaceEligibleType(type: string): boolean {
  return SURFACE_EVENT_TYPES.has(type);
}

/** 是 surface 类型且确实带了 surfaceOp。 */
export function isSurfaceEvent(event: SessionEvent): boolean {
  if (!SURFACE_EVENT_TYPES.has(event.type)) {
    return false;
  }
  return (event as SessionEvent<'user/message'>).surfaceOp !== undefined;
}

/** 在自己日志位置上追加进 surface（而非作为替换副本）的事件。 */
export function isAppendSurfaceEvent(event: SessionEvent): boolean {
  return isSurfaceEvent(event) && (event as SessionEvent<'user/message'>).surfaceOp === 'append';
}

/** 遮蔽了一段已存在 surface 节点的替换事件。 */
export function isReplacementSurfaceEvent(event: SessionEvent): boolean {
  return isSurfaceEvent(event) && (event as SessionEvent<'user/message'>).surfaceOp !== 'append';
}

/**
 * 折叠过程中的 surface 状态，字段与 dsh-session/lib/types/surface.js 的 init 一致：
 * nodes / replaceGeneration / contentGeneration 之外还有两张缓存，
 * projectedMessages 按 seq 缓存已解析的消息，projections 记哪些事件带纯解释器。
 */
export interface SurfaceState {
  /** 当前模型可见节点的 seq，按顺序。 */
  nodes: SessionSeq[];
  /** 发生过多少次替换，用于判断是否需要重建。 */
  replaceGeneration: number;
  /** 内容变化代数；每次节点集合改变都加一。 */
  contentGeneration: number;
  /** 已解析消息的缓存，键是 event seq。 */
  projectedMessages: Map<SessionSeq, Object>;
  /** 带纯解释器的事件类型集合。 */
  projections: Set<string>;
}

export function emptySurface(): SurfaceState {
  return {
    nodes: [],
    replaceGeneration: 0,
    contentGeneration: 0,
    projectedMessages: new Map<SessionSeq, Object>(),
    projections: new Set<string>()
  };
}

/** 一次替换定位到的区间。 */
interface ReplacementRange {
  startIdx: number;
  endIdx: number;
  shadowedSeqs: SessionSeq[];
}

/** 在不动当前状态的前提下定位替换区间，越界即抛。 */
function replacementRange(state: SurfaceState, startSeq: SessionSeq,
  endSeq: SessionSeq): ReplacementRange {
  const startIdx = state.nodes.indexOf(startSeq);
  if (startIdx === -1) {
    throw new Error(`surface replace: start seq ${startSeq} not found in surface`);
  }
  const endIdx = state.nodes.indexOf(endSeq);
  if (endIdx === -1) {
    throw new Error(`surface replace: end seq ${endSeq} not found in surface`);
  }
  if (startIdx > endIdx) {
    throw new Error(`surface replace: start seq ${startSeq} (index ${startIdx}) is after end seq ${endSeq} (index ${endIdx})`);
  }
  return { startIdx: startIdx, endIdx: endIdx, shadowedSeqs: state.nodes.slice(startIdx, endIdx + 1) };
}

/**
 * 把一条事件折进 surface。非 surface 事件原样返回同一个 state。
 * 替换会在原位置放新节点，被遮蔽的区间整体消失；追加放在尾部。
 */
export function applySurface(state: SurfaceState, event: SessionEvent): SurfaceState {
  if (!isSurfaceEvent(event)) {
    return state;
  }
  const intent = event as SessionEvent<'user/message'>;
  const op = intent.surfaceOp;
  if (op === 'append') {
    const nodes = state.nodes.concat([event.seq]);
    return {
      nodes: nodes,
      replaceGeneration: state.replaceGeneration,
      contentGeneration: state.contentGeneration + 1,
      projectedMessages: state.projectedMessages,
      projections: state.projections
    };
  }
  if (op.startSeq >= event.seq || op.endSeq >= event.seq) {
    throw new Error(`surface replace at seq ${event.seq}: startSeq and endSeq must reference earlier events`);
  }
  const range = replacementRange(state, op.startSeq, op.endSeq);
  const sources = intent.sourceEventSeqs !== undefined ? intent.sourceEventSeqs : [];
  const missing: SessionSeq[] = range.shadowedSeqs.filter((seq: SessionSeq) => sources.indexOf(seq) < 0);
  if (missing.length > 0) {
    throw new Error(`surface replace: sourceEventSeqs must include every shadowed surface node; missing ${missing.join(', ')}`);
  }
  const nodes = state.nodes.slice(0, range.startIdx)
    .concat([event.seq])
    .concat(state.nodes.slice(range.endIdx + 1));
  return {
    nodes: nodes,
    replaceGeneration: state.replaceGeneration + 1,
    contentGeneration: state.contentGeneration + 1,
    projectedMessages: state.projectedMessages,
    projections: state.projections
  };
}
// 压缩：选一段 surface 节点，用一条摘要替换它们。
//
// 选择规则照 dsh-compaction-basic/lib/index.js:410-433（selectCompactableRange）：
//   1. 起点是第一个非 system 的 surface 节点；node 0 是 system/message 时永不进入区间；
//   2. 从尾部往前累加 token，达到保留预算 retainTokens 的那个节点成为保留尾巴的起点；
//   3. 不能把 assistant 的 tool-call 与它的 tool/result 拆到两边，越界就往前退；
//   4. 起点与保留起点重合时返回 null（没有可压的东西）。
//
// 本文件只做位置与预算的判断，不对消息计价 —— 计价由调用方传入 pricedNodes，
// 免得在这里编一个 token 估算口径。

/** 要压掉的节点区间，两端都含。 */
export interface Region {
  startSeq: number;
  endSeq: number;
}

/** 一次压缩的结果，给状态行用。 */
export interface CompactOutcome {
  from: number;
  to: number;
  tokens: number;
}

/** 一个带价钱的 surface 节点。 */
export interface PricedNode {
  seq: number;
  tokens: number;
}

/** 这个 seq 上是不是 system 消息（node 0 的 system 保留为指令头）。 */
export type SystemHeadCheck = (seq: number) => boolean;

/** 在 seq 之前，tool call 与 result 是否已全部配对。 */
export type ToolPairingCheck = (seq: number) => boolean;

/**
 * 选出下一个可压缩区间。返回 null 表示没有安全可压的一段。
 *
 * @param surfaceNodes 当前 surface 的 seq 序列（含 system 头）
 * @param pricedNodes 与 surfaceNodes 一一对应的节点价钱
 * @param isSystemHead node 0 是否 system
 * @param balancedBefore 某个 seq 之前 tool 配对是否平衡
 * @param retainTokens 至少原样保留的尾部预算
 */
export function selectCompactableRange(surfaceNodes: number[], pricedNodes: PricedNode[],
  isSystemHead: SystemHeadCheck, balancedBefore: ToolPairingCheck,
  retainTokens: number): Region | null {
  if (pricedNodes.length === 0 || surfaceNodes.length !== pricedNodes.length) {
    return null;
  }
  const firstIdx = surfaceNodes.length > 0 && isSystemHead(surfaceNodes[0]) ? 1 : 0;
  let accumulated = 0;
  let keepFromIdx = pricedNodes.length;
  for (let index = pricedNodes.length - 1; index >= 0; index -= 1) {
    accumulated += pricedNodes[index].tokens;
    keepFromIdx = index;
    if (accumulated >= retainTokens) {
      break;
    }
  }
  if (keepFromIdx <= firstIdx) {
    return null;
  }
  while (keepFromIdx > firstIdx) {
    if (balancedBefore(surfaceNodes[keepFromIdx])) {
      break;
    }
    keepFromIdx -= 1;
  }
  if (keepFromIdx <= firstIdx) {
    return null;
  }
  return { startSeq: surfaceNodes[firstIdx], endSeq: surfaceNodes[keepFromIdx - 1] };
}

/** 区间内合计的价钱。 */
export function regionTokens(pricedNodes: PricedNode[], region: Region): number {
  let sum = 0;
  for (const node of pricedNodes) {
    if (node.seq >= region.startSeq && node.seq <= region.endSeq) {
      sum += node.tokens;
    }
  }
  return sum;
}
/** 没有压成的原因。界面按原因分别显示，不再一律说「无需压缩」。 */
export type CompactStop = 'busy' | 'no-region' | 'empty-summary' | 'not-smaller';

/** 一次压缩尝试的结果：压成了给 outcome，没压成给原因。 */
export interface CompactAttempt {
  outcome: CompactOutcome | null;
  stop: CompactStop | null;
}

// 会话统计：从事件流折叠出来，供状态栏显示。
//
// 只在有读数时给数：新会话没有缓存占比，也没有上下文占用，印成 0 会被读成故障。
// 与 dsh-session-stats 同一口径：轮数数 turn/start，步数数 step/start，
// token 取每条 assistant/message 上 provider 报的 usage。

import type { SessionEvent } from './Events.ts';
import type { Usage } from '../loop/Types.ts';
import { billedInputTokens, totalTokensOf } from '../loop/Types.ts';

export interface SessionStats {
  /** 开始了多少轮。 */
  turns: number;
  /** 走了多少步（一次请求算一步）。 */
  steps: number;
  /** 全会话计费的输入加输出。 */
  totalTokens: number;
  /** 缓存命中占 prompt 的百分比；-1 表示还没收到过 usage。 */
  cacheHit: number;
  /** 上下文占用百分比；0 表示未知或未配置窗口。 */
  pressure: number;
  /** 最近一次请求的 prompt token 数，也就是当前上下文大小；0 表示还没有读数。 */
  contextTokens: number;
  /** 全会话的输出速率（tok/s，累计输出 / 累计生成时长）；0 表示还没有可算的区间。 */
  rate: number;
  /** 全会话的生成 token 数（completion + reasoning）。 */
  outputTokens: number;
  /** 全会话的生成时长（毫秒），只累加真正测到生成区间的步。 */
  generationMs: number;
}

export function emptyStats(): SessionStats {
  return {
    turns: 0, steps: 0, totalTokens: 0, cacheHit: -1, pressure: 0, contextTokens: 0, rate: 0,
    outputTokens: 0, generationMs: 0
  };
}

/** 折叠整个事件流。只认最后一条 usage 决定 pressure，累计量对整段求和。 */
export function foldStats(events: SessionEvent[], contextWindow: number): SessionStats {
  let turns = 0;
  let steps = 0;
  let totalTokens = 0;
  let promptTokens = 0;
  let cacheRead = 0;
  let lastPrompt = -1;
  let sawUsage = false;
  let stepStartedAt = -1;
  let lastCompletion = 0;
  let lastRate = 0;
  // 这一步是否已经有精确的生成区间；没有就用整步墙钟时间兜底（旧日志没有这个字段）。
  let stepCompletion = 0;
  let stepHadElapsed = false;
  // 速率按全会话累计：单步只有几百毫秒时，除出来的数在 200~900 tok/s 之间乱跳，
  // 那不是模型速度，是采样窗口太短。累计口径与 dsh-session-stats 的稳定读数一致。
  let outputTotal = 0;
  let generationTotal = 0;

  for (const event of events) {
    if (event === undefined || event === null) {
      continue;
    }
    if (event.type === 'turn/start') {
      turns += 1;
      continue;
    }
    if (event.type === 'step/start') {
      steps += 1;
      stepStartedAt = event.time;
      stepCompletion = 0;
      stepHadElapsed = false;
      continue;
    }
    if (event.type === 'step/end') {
      if (!stepHadElapsed && stepStartedAt > 0 && event.time > stepStartedAt && stepCompletion > 0) {
        lastRate = (stepCompletion * 1000) / (event.time - stepStartedAt);
      }
      stepStartedAt = -1;
      continue;
    }
    if (event.type !== 'assistant/message') {
      continue;
    }
    const data = event.data as Record<string, Object>;
    if (data === undefined || data === null) {
      continue;
    }
    const usage = data['usage'] as Usage;
    if (usage === undefined || usage === null) {
      continue;
    }
    sawUsage = true;
    totalTokens += totalTokensOf(usage);
    const billed = billedInputTokens(usage);
    promptTokens += billed;
    cacheRead += usage.cacheReadTokens;
    // 最新一次请求的 prompt 才是上下文实际占用，累加值没有意义。
    lastPrompt = billed;
    lastCompletion = usage.completionTokens + usage.reasoningTokens;
    stepCompletion = lastCompletion;
    // 速率优先用这一步自己测到的生成区间；没测到就等 step/end 用墙钟时间兜底。
    // 分子分母必须来自同一批步：只累加同时有输出与生成时长的步，否则旧日志里
    // 缺 elapsedMs 的那些步会把分子抬高、分母不动，算出 953 这种假速率。
    if (usage.elapsedMs > 0 && lastCompletion > 0) {
      lastRate = (lastCompletion * 1000) / usage.elapsedMs;
      outputTotal += lastCompletion;
      generationTotal += usage.elapsedMs;
      stepHadElapsed = true;
    }
  }

  const stats = emptyStats();
  stats.turns = turns;
  // 样本太小就不给读数：几百 token 除以几百毫秒能算出三位数，那不是吞吐。
  stats.rate = generationTotal >= 300 && outputTotal >= 200
    ? (outputTotal * 1000) / generationTotal : 0;
  stats.outputTokens = outputTotal;
  stats.generationMs = generationTotal;
  stats.steps = steps;
  stats.totalTokens = totalTokens;
  stats.contextTokens = lastPrompt >= 0 ? lastPrompt : 0;
  if (sawUsage && promptTokens > 0) {
    stats.cacheHit = Math.round((cacheRead / promptTokens) * 1000) / 10;
  }
  if (contextWindow > 0 && lastPrompt >= 0) {
    const pct = (lastPrompt / contextWindow) * 100;
    stats.pressure = pct > 100 ? 100 : Math.round(pct * 10) / 10;
  }
  return stats;
}

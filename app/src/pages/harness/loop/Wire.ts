import type { ChatMessage } from './Types.ts';

/**
 * 服务端对工具调用有一条硬协议：带 `tool_calls` 的助手消息后面必须**紧跟**这些
 * `tool_call_id` 的结果消息。历史里这一对可能被别的消息插开（旧版本答题时会往会话里
 * 注入一条用户消息，结果就落在它后面），一旦写进日志，之后每一轮请求都会被整条拒绝。
 *
 * 所以在发送边界上兜一次：把结果提到紧邻助手消息的位置，缺结果的调用补一条说明。
 * 只在构造请求时做，不改日志本身——日志保留事实，线上消息满足协议。
 */
export function pairToolResults(messages: ChatMessage[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  const used: boolean[] = [];
  for (let i = 0; i < messages.length; i++) {
    used.push(false);
  }
  for (let i = 0; i < messages.length; i++) {
    if (used[i]) {
      continue;
    }
    const message = messages[i];
    used[i] = true;
    out.push(message);
    if (message.role !== 'assistant' || message.toolCalls.length === 0) {
      continue;
    }
    // 这条助手消息要的那几个结果，按调用顺序提到它后面。
    for (const call of message.toolCalls) {
      let found = false;
      for (let j = i + 1; j < messages.length; j++) {
        if (used[j]) {
          continue;
        }
        const candidate = messages[j];
        if (candidate.role === 'tool' && candidate.toolCallId === call.id) {
          used[j] = true;
          out.push(candidate);
          found = true;
          break;
        }
      }
      if (!found) {
        // 没有结果也必须占位：少一条，整轮请求都会被服务端拒掉。
        out.push({
          id: 0,
          role: 'tool',
          source: 'tool',
          content: 'error: 这次调用的结果没有留下记录',
          reasoning: '',
          context: '',
          images: [],
          toolCalls: [],
          toolCallId: call.id
        });
      }
    }
  }
  return out;
}

/**
 * 配对之后仍然违约的位置，供发送前记日志用。正常情况下应当恒为空——
 * 一旦不为空，服务端会用一条 400 拒绝整轮，而那正是最难从客户端现象反推的错误。
 */
export function unpairedCalls(messages: ChatMessage[]): string[] {
  const bad: string[] = [];
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (message.role !== 'assistant' || message.toolCalls.length === 0) {
      continue;
    }
    let at = i + 1;
    for (const call of message.toolCalls) {
      const next = at < messages.length ? messages[at] : undefined;
      if (next === undefined || next.role !== 'tool' || next.toolCallId !== call.id) {
        bad.push(call.id);
      }
      at += 1;
    }
  }
  return bad;
}

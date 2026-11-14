import { ChatLine } from '../view/ChatPanel';
import { makeLine } from '../view/ChatBlocks';
import { ChatMessage } from '../harness/loop/Types';
import { SessionStats } from '../harness/session/Stats';

/**
 * 会话事件到对话行的转换。页面只负责把结果塞回 @State，不再在这里写「哪两种事件要合并」
 * 这类规则——它们是转写格式的一部分，跟谁渲染无关。
 */

/** 追加一段流式事件。text/thought 与上一条同类合并，其余各成一行。 */
export function appendLine(current: ChatLine[], kind: string, text: string): ChatLine[] {
  const lines: ChatLine[] = current.slice();
  const last = lines.length > 0 ? lines[lines.length - 1] : undefined;

  if (kind === 'text') {
    if (last !== undefined && last.kind === 'assistant') {
      lines[lines.length - 1] = makeLine('assistant', last.text + text, '');
    } else {
      lines.push(makeLine('assistant', text, ''));
    }
    return lines;
  }
  if (kind === 'thought') {
    if (last !== undefined && last.kind === 'thought') {
      lines[lines.length - 1] = makeLine('thought', last.text + text, '');
    } else {
      lines.push(makeLine('thought', text, ''));
    }
    return lines;
  }
  if (kind === 'tool') {
    // "name args" from the loop: the name is what the process line shows, the args are detail.
    const cut = text.indexOf(' ');
    const name = cut > 0 ? text.substring(0, cut) : text;
    const args = cut > 0 ? text.substring(cut + 1) : '';
    lines.push(makeLine('tool', args, name));
  } else if (kind === 'result') {
    const name = last !== undefined && last.kind === 'tool' ? last.name : '';
    lines.push(makeLine('tool', text, name));
  } else if (kind === 'error') {
    lines.push(makeLine('error', text, ''));
  } else if (kind === 'user') {
    lines.push(makeLine('user', text, ''));
  }
  return lines;
}

/** 从会话历史重建整份转写：恢复会话或切换工程时用。 */
export function rebuildLines(messages: ChatMessage[]): ChatLine[] {
  const lines: ChatLine[] = [];
  for (const message of messages) {
    if (message.role === 'user') {
      // 运行时注入不是一句说过的话，但也不是该藏起来的东西：标成 injection 行。
      if (message.source === 'runtime') {
        lines.push(makeLine('injection', message.content, '上下文'));
        continue;
      }
      lines.push(makeLine('user', message.content, ''));
    } else if (message.role === 'assistant') {
      if (message.reasoning.length > 0) {
        lines.push(makeLine('thought', message.reasoning, ''));
      }
      if (message.content.length > 0) {
        lines.push(makeLine('assistant', message.content, ''));
      }
    } else if (message.role === 'tool') {
      lines.push(makeLine('tool', message.content, ''));
    }
  }
  return lines;
}

/** 状态栏那组数字。读不出来时返回 undefined：状态栏是装饰，不该打断启动。 */
export function readStats(session: Session): SessionStats | undefined {
  try {
    return session.statsForBar();
  } catch (error) {
    return undefined;
  }
}

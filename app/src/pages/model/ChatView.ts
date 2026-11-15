// 三个类型都用 import type：它们只是结构声明，运行时不存在。原先 ChatLine 是从
// view/ChatPanel（.ets）拿的，多绕一层把一个纯逻辑文件拖进了 UI 模块，Node 也加载不了它。
import type { ChatLine } from './Lines';
import { makeLine } from './Lines.ts';
import type { ChatMessage } from '../harness/loop/Types';
import type { SessionStats } from '../harness/session/Stats';

/**
 * 会话事件到对话行的转换。页面只负责把结果塞回 @State，不再在这里写「哪两种事件要合并」
 * 这类规则——它们是转写格式的一部分，跟谁渲染无关。
 */

/**
 * 本段内最后一条某种行。段以 user（一轮的开始）与 tool（一次调用）为界：一次调用就是一次
 * 独立请求，它前后的正文是两条 assistant message，各自成行——合成一行会把两段话焊死
 * （中间没有空行，读起来是一坨）。渲染时由 itemsOf 把同一 turn 的正文用空行接成一块。
 */
function lastOfKind(lines: ChatLine[], kind: string): number {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].kind === kind) {
      return i;
    }
    if (lines[i].kind === 'user' || lines[i].kind === 'tool' ||
      lines[i].kind === 'injection' || lines[i].kind === 'checkpoint') {
      return -1;
    }
  }
  return -1;
}

/** 追加一段流式事件。text/thought 与上一条同类合并，其余各成一行。 */
export function appendLine(current: ChatLine[], kind: string, text: string): ChatLine[] {
  const lines: ChatLine[] = current.slice();
  const last = lines.length > 0 ? lines[lines.length - 1] : undefined;

  // 正文有两种叫法：流式事件叫 text，历史重建叫 assistant。两种都认。
  if (kind === 'text' || kind === 'assistant') {
    const at = lastOfKind(lines, 'assistant');
    if (at >= 0) {
      lines[at] = makeLine('assistant', lines[at].text + text, '');
    } else {
      lines.push(makeLine('assistant', text, ''));
    }
    return lines;
  }
  if (kind === 'thought') {
    // 流式里 reasoning 与 text 交错到达（思考几段、正文一段、再思考），只跟紧邻行合并的话
    // 每交错一次就新起一行，正文会被切成碎片夹在思考中间。所以合并到「本段内」最后一条同类行：
    // 段以 user / tool 行为界。思考块还固定插在正文之前——阅读顺序是「先想后说」。
    const at = lastOfKind(lines, 'thought');
    if (at >= 0) {
      lines[at] = makeLine('thought', lines[at].text + text, '');
    } else {
      const spoken = lastOfKind(lines, 'assistant');
      const line = makeLine('thought', text, '');
      if (spoken >= 0) {
        lines.splice(spoken, 0, line);
      } else {
        lines.push(line);
      }
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
  } else {
    // 未知事件类型：宁可当正文显示，也不要静默丢掉。丢掉的症状是「从某处起后面全没了」，
    // 看上去像渲染层坏了，实际是名字没对上。
    //
    // 但空正文不属于「被丢了的内容」：`done` 这类控制事件本来就带空串，造出一条空 assistant
    // 行会顶掉真答案——itemsOf 取本轮最后一条 assistant 当答案，那条空的排在后面就成了答案，
    // 真正的正文被折进收起的过程组里，界面上显示成一整片空白。
    if (text.length > 0) {
      lines.push(makeLine('assistant', text, ''));
    }
  }
  return lines;
}

/**
 * 从会话历史重建整份转写：恢复会话或切换工程时用。
 *
 * 压缩点不另立表示：它就是日志里那条 source 为 `checkpoint` 的 user/message，位置即消息位置。
 * 早先在渲染层拿独立的记账事件反推位置，反推结果没有归属，只能排到最后——重新打开时看上去
 * 像刚刚发生的事，而它讲的是一段已经看不见的过去。
 */
export function rebuildLines(messages: ChatMessage[]): ChatLine[] {
  const lines: ChatLine[] = [];
  for (const message of messages) {
    if (message.role === 'user') {
      // 运行时注入不是一句说过的话，但也不是该藏起来的东西：标成 injection 行。
      if (message.source === 'runtime') {
        lines.push(makeLine('injection', message.content, '上下文'));
        continue;
      }
      if (message.source === 'checkpoint') {
        // 首行（替代了哪一段、多大）当标题，正文展开可见。
        const cut = message.content.indexOf('\n');
        const head = cut >= 0 ? message.content.substring(0, cut) : message.content;
        lines.push(makeLine('checkpoint', message.content, head));
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

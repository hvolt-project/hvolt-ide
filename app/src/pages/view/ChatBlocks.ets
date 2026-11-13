// 对话行：一条事件派生一行，一行一件事。
//
// 与 dsh-client-ui-chat 的渲染方式对齐：每条注入、每次工具调用、每段推理各自是一行
// DisclosureRow（标题 + 收起摘要 + 展开内容，见 client.js:4982 的 DisclosureRow 用法），
// 不是把连续过程并成一块再按档位决定开合。

export type ChatKind = 'user' | 'assistant' | 'thought' | 'tool' | 'error' | 'injection';

export interface ChatLine {
  kind: ChatKind;
  /** 正文；工具行是参数摘要，推理行是全文。 */
  text: string;
  /** 工具名，或注入的生产者名。 */
  name: string;
}

/** 造一行。身份由 lineKey 从内容派生，不再另存 id。 */
export function makeLine(kind: ChatKind, text: string, name: string): ChatLine {
  return { kind: kind, text: text, name: name };
}

/**
 * 一行在重建之后仍认得出的键。transcript 每次刷新都会重新建行、id 全换，
 * 开合状态若挂在 id 上，刷新一次就全被收起。
 */
export function lineKey(line: ChatLine): string {
  return line.kind + ':' + String(line.text.length) + ':' + line.text.substring(0, 24);
}

/** 这一行是否可折叠：只有过程类（推理、工具、注入）能收起。 */
export function foldable(kind: ChatKind): boolean {
  return kind === 'thought' || kind === 'tool' || kind === 'injection';
}

/** 收起时显示的一行标题。 */
export function lineTitle(line: ChatLine): string {
  if (line.kind === 'thought') {
    const size = line.text.length;
    return size === 0 ? '思考' : '思考（' + String(size) + ' 字）';
  }
  if (line.kind === 'tool') {
    const name = line.name.length > 0 ? line.name : '工具';
    const head = firstLine(line.text);
    return head.length > 0 ? name + ' · ' + head : name;
  }
  if (line.kind === 'injection') {
    const name = line.name.length > 0 ? line.name : '上下文';
    return name;
  }
  return firstLine(line.text);
}

/** 展开后显示的内容。 */
export function lineDetail(line: ChatLine): string {
  if (line.kind === 'thought' || line.kind === 'tool') {
    return line.text;
  }
  return '';
}

/** 第一行，过长截断。工具的参数可能很长，标题只要够认出是哪一次调用。 */
function firstLine(text: string): string {
  const cut = text.indexOf('\n');
  const head = cut >= 0 ? text.substring(0, cut) : text;
  return head.length > 64 ? head.substring(0, 64) + '…' : head;
}
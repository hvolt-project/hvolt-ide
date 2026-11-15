// 对话行：一条事件派生一行，一行一件事。
//
// 与 dsh-client-ui-chat 的渲染方式对齐：每条注入、每次工具调用、每段推理各自是一行
// DisclosureRow（标题 + 收起摘要 + 展开内容，见 client.js:4982 的 DisclosureRow 用法），
// 不是把连续过程并成一块再按档位决定开合。
//
// 纯逻辑、无外部依赖，住在 `.ts` 里是为了让 `node --test` 能加载真代码（test/lines.test.ts）。
// 注意：本文件不 import 任何模块，加依赖会把它重新变成不可测的模块。

export type ChatKind = 'user' | 'assistant' | 'thought' | 'tool' | 'error' | 'injection' | 'checkpoint';

export interface ChatLine {
  kind: ChatKind;
  /** 正文；工具行是参数摘要，推理行是全文。 */
  text: string;
  /** 工具名，或注入的生产者名。 */
  name: string;
}

/** 造一行。行本身不带身份：展示项的身份按它在数组里的位置算，正文增长不动它。 */
export function makeLine(kind: ChatKind, text: string, name: string): ChatLine {
  return { kind: kind, text: text, name: name };
}

// ── 阈值：三处截断各有各的展示面，数字不一样不是笔误 ──────────────────────────
//
// 64 是单行正文（user / error / checkpoint 的标题行）首行的最长显示——那是一整行宽度。
// 26 是「思考 · 」前缀之后还能占一行的宽度——前缀本身吃掉了十来个字，而且推理行组内缩进
//     22、用等宽 11 号字，同样的字数在组里更宽。
//
// 两个数字服务两种用途，不要「统一」它们：把 26 提到 64 会让组头压过正文，
// 把 64 降到 26 会把标题截成没信息量的碎片。

/** 单行正文首行的最长显示字数。 */
export const TITLE_HEAD_CHARS: number = 64;
/** 「思考 · 」前缀之后还能占一行的宽度。 */
export const THOUGHT_TITLE_CHARS: number = 26;

/** 这一行是否可折叠：只有过程类（推理、工具、注入）能收起。 */
export function foldable(kind: ChatKind): boolean {
  return kind === 'thought' || kind === 'tool' || kind === 'injection' || kind === 'checkpoint';
}

/** 收起时显示的一行标题。 */
export function lineTitle(line: ChatLine): string {
  if (line.kind === 'thought') {
    // 「思考（1210 字）」这种标题没有信息，还比正文更显眼：照 DSH 的 ReasoningRow 用
    // 「思考」+ 首行摘要，摘要去掉 ** 标记（DSH 是 replaceAll("**","")；只删一对照样会留下
    // 闭合的那一对，标题就变成「结论**：…」）。
    const head = headOf(line.text).split('**').join('').trim();
    if (head.length === 0) {
      return '思考';
    }
    return '思考 · ' + (head.length > THOUGHT_TITLE_CHARS ?
      head.substring(0, THOUGHT_TITLE_CHARS) + '…' : head);
  }
  if (line.kind === 'tool') {
    const name = line.name.length > 0 ? line.name : '工具';
    const head = headOf(line.text).trim();
    // 结果是 JSON 信封时只给状态：把整段结果糊在标题上，一眼看去全是转义字符。
    // 判据是「带 ok / status 字段」而不是「以 { 开头」：工具的参数本身也是 JSON，
    // 只按花括号判会把参数一起吞掉，标题永远显示「完成」，看不出这次调用干了什么。
    const isEnvelope = head.indexOf('"ok":') >= 0 || head.indexOf('"status":') >= 0;
    if (isEnvelope) {
      const failed = head.indexOf('"ok":false') >= 0 || head.indexOf('"status":"error"') >= 0;
      return name + (failed ? ' · 失败' : ' · 完成');
    }
    return head.length > 0 ? name + ' · ' + head : name;
  }
  if (line.kind === 'injection') {
    const name = line.name.length > 0 ? line.name : '上下文';
    return name;
  }
  // 压缩点：标题就是它自己的首行（替代了哪一段、多大），正文收起时不可见。
  if (line.kind === 'checkpoint') {
    return line.name.length > 0 ? line.name : headOf(line.text);
  }
  return headOf(line.text);
}

/** 展开后显示的内容。 */
export function lineDetail(line: ChatLine): string {
  // 过程类（推理、工具、错误、注入）展开就是全文。错误与注入也算过程类里可展开的：
  // foldable 说注入可折叠、折叠的语义就是「展开有内容看」，detail 若是空串，展开就是空块。
  if (line.kind === 'thought' || line.kind === 'tool' || line.kind === 'error' ||
    line.kind === 'injection') {
    return line.text;
  }
  // 压缩点展开后是被压缩内容的摘要，首行已经当标题显示过了。
  if (line.kind === 'checkpoint') {
    const cut = line.text.indexOf('\n');
    return cut >= 0 ? line.text.substring(cut + 1).trim() : '';
  }
  // user / assistant 本来就全文可见，不存在另一份展开内容。
  return '';
}

/**
 * 第一行，过长截断。工具的参数可能很长，标题只要够认出是哪一次调用。
 *
 * 注意与 Format.ts 的 firstLine 同名不同义：那个会优先挑出含 ✗ 的失败行（给工具输出用），
 * 这个只取第一行。所以这里叫 headOf，避免两处混用。
 */
export function headOf(text: string): string {
  const cut = text.indexOf('\n');
  const head = cut >= 0 ? text.substring(0, cut) : text;
  return head.length > TITLE_HEAD_CHARS ? head.substring(0, TITLE_HEAD_CHARS) + '…' : head;
}
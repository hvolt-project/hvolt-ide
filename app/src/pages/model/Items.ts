// 对话流的纯逻辑：行数组 → 该显示的项。
//
// 从 view/ChatStream.ets 下沉到这里，为的是 `node --test` 能加载真代码（test/items.test.ts）。
// 本文件不碰 ArkUI：没有组件、没有 @Builder、没有 $r，也没有 IDataSource——那些是实现平台
// 接口的东西，留在 ChatStream.ets 里。
//
// 判定口径（docs/dsh-transcript-alignment.md §17）：
//   grouped     = collapsed || (history && closed)
//   alwaysOpen  = !closed || 组内有错误
//   collapsed   = foldable(该行) 且未手动展开（error 不可折叠，故错误常显）
//   reasoning   = 折叠档下随组隐藏（进组，不进正文流）

// 行级语义（标题 / 展开正文 / 是否可折叠）只有 Lines.ts 一份实现，本文件不保留同义副本。
// 值导入带 .ts 扩展名：Node 的 ESM 解析要求写全（ArkTS 侧同样接受），运行期才找得到真模块。
// 类型导入不带扩展名也无妨（会被擦除），但这里统一写全，避免同一条路径出现两种写法。
import type { ChatLine } from './Lines.ts';
import { foldable, lineTitle } from './Lines.ts';
// 只导类型：Policy.ets 是 .ets，运行期解析不到；这个 import 被擦除，不会真的去加载它。
import type { ChatPresentationPolicy } from './Policy';

// ── 展示种类（StreamItem.kind）：字符串常量，杜绝散落的字面量比较 ─────────────────
export const KIND_USER: string = 'user';
export const KIND_GROUP: string = 'group';
export const KIND_MARKDOWN: string = 'markdown';
export const KIND_TOOL: string = 'tool';
export const KIND_REASONING: string = 'reasoning';
export const KIND_ERROR: string = 'error';
export const KIND_INJECTION: string = 'injection';

// ── 活动种类：键对齐 DSH 的 message.stepProcess.*（驱动组头文案与图标） ───────────
export const ACT_THINKING: string = 'thinking';
export const ACT_READ: string = 'read';
export const ACT_WRITE: string = 'write';
export const ACT_EDIT: string = 'edit';
export const ACT_SEARCH: string = 'search';
export const ACT_COMMANDS: string = 'commands';
export const ACT_CODE: string = 'code';
export const ACT_WEB_SEARCH: string = 'webSearch';
export const ACT_WEB_FETCH: string = 'webFetch';
export const ACT_SUBAGENTS: string = 'subagents';
export const ACT_PLAN: string = 'plan';
/** 兜底活动：认不出的工具名归入「工具」一类。 */
export const ACT_TOOLS: string = 'tools';

// ── 版式：组内次级内容 ──────────────────────────────────────────────────────
// 这里刻意没有「缩进」「宽度上限」「高度上限」三个常量：组内内容就是正文的次级版本，
// 跟着页面同宽、同滚。曾经给过缩进 22、宽 88%、限高 141 的内滚窗口，结果是长思考被塞进
// 一条小缝里，读起来像卡住不动。
export const GROUP_RADIUS: number = 8;
/**
 * 展开的组最高多少（DSH 的 capped + useProcessScroll）：再长的过程也不该把整条对话顶走。
 * 早先写 141 太窄，长思考只剩一条缝；这里给 320，超出就在组内滚。
 */
export const GROUP_MAX_HEIGHT: number = 320;
/** 组标题最多列几类活动（更多就「等」）。 */
export const GROUP_TITLE_MAX_KINDS: number = 3;
/**
 * 组头热区：最小一行高 + 上下内边距。
 *
 * 不要写成固定 height(24)——文字在 13 号字下实际占得更高，固定高度会让文字溢出到热区之外，
 * 点标题中下部就落空，表现为「组头点不开」。
 */
export const GROUP_HEADER_MIN: number = 24;
export const GROUP_HEADER_PAD: number = 3;

// ── 字号 ──────────────────────────────────────────────────────────────────
export const TYPE_MICRO: number = 10;
export const TYPE_TINY: number = 11;
export const TYPE_SMALL: number = 12;
export const TYPE_MEDIUM: number = 13;
export const TYPE_BODY: number = 14;
export const MONO_FAMILY: string = 'monospace';

// ── 活动短语表的下标 ──────────────────────────────────────────────────────
export const PHRASE_LIVE: number = 0;
export const PHRASE_DONE: number = 1;

/**
 * 折叠时机里「等下一条输入」那一档的字面量。
 *
 * 这里不能调 Policy.ets 的 collapseTimingOf（.ets 的值在 Node 下解析不到），所以直接比字符串。
 * 这是安全的：调用方 ChatPanel.policy() 已经用 collapseTimingOf() 归一过，
 * 传进来的 policy.collapseTiming 必然是合法值（'immediate' | 'next-input'）。
 */
const TIMING_NEXT_INPUT: string = 'next-input';

export interface StreamItem {
  key: string;
  /** user | group | markdown | tool | reasoning | error | injection */
  kind: string;
  text: string;
  /** 标题：组头是动作短语，工具是工具名+状态，思考固定「思考」。 */
  title: string;
  closed: boolean;
  process: ChatLine[];
  /**
   * 是否允许收起。组件拿它配合 opened 自己算开合，而不是吃 collapsed：
   * LazyForEach 复用同 key 的项时不会重新赋值 @Prop，开合状态传不进去；@Link 可以。
   */
  closable: boolean;
  /** 收起态（closable 且未手动展开）。数据层的判定结果，供测试与比较用。 */
  collapsed: boolean;
  /** 活动种类：驱动组头图标与文案（thinking/read/write/commands/code/webSearch/...）。 */
  activity: string;
  /** 组内静止行的标题是否带首行预览（DSH 的 settledReasoningPreview）。 */
  memberPreview: boolean;
}

// ── 活动种类：工具名 → DSH 的活动类别（message.stepProcess.* 的键） ────────────────────
//
// 精确映射，不用子串匹配：`indexOf('read')` 会把 `thread` / `already_*` 误判成「读取文件」。
// 表在顶层构造一次（构造函数逐条 set，ArkTS 严格模式对对象字面量做类型时不友好）。
function makeActivityOfTool(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  table.set('read', ACT_READ);
  table.set('read_file', ACT_READ);
  table.set('readimage', ACT_READ);
  table.set('read_image', ACT_READ);
  table.set('write', ACT_WRITE);
  table.set('write_file', ACT_WRITE);
  table.set('edit', ACT_EDIT);
  table.set('apply_patch', ACT_EDIT);
  table.set('patch', ACT_EDIT);
  table.set('grep', ACT_SEARCH);
  table.set('glob', ACT_SEARCH);
  table.set('search', ACT_SEARCH);
  table.set('search_code', ACT_SEARCH);
  table.set('shell', ACT_COMMANDS);
  table.set('sandbox_sh', ACT_COMMANDS);
  table.set('bash', ACT_COMMANDS);
  table.set('sh', ACT_COMMANDS);
  table.set('js_eval', ACT_CODE);
  table.set('bash_run', ACT_CODE);
  table.set('run', ACT_CODE);
  table.set('web_search', ACT_WEB_SEARCH);
  table.set('web_fetch', ACT_WEB_FETCH);
  table.set('fetch', ACT_WEB_FETCH);
  table.set('subagent', ACT_SUBAGENTS);
  table.set('subagent_fork', ACT_SUBAGENTS);
  table.set('spawn_agent', ACT_SUBAGENTS);
  table.set('todo_write', ACT_PLAN);
  table.set('todo_read', ACT_PLAN);
  table.set('plan', ACT_PLAN);
  // 本工程自己的工具：认不出来会落到「调用工具」这一档，组头图标也就成了兜底的横线。
  table.set('read_log', ACT_READ);
  table.set('sdk_search', ACT_SEARCH);
  table.set('ide', ACT_EDIT);
  table.set('hvolt', ACT_COMMANDS);
  return table;
}

const ACTIVITY_OF_TOOL: Map<string, string> = makeActivityOfTool();

/** 工具名 → 活动类别；查不到归 ACT_TOOLS。 */
export function activityOfTool(name: string): string {
  const activity = ACTIVITY_OF_TOOL.get(name.toLowerCase());
  return activity === undefined ? ACT_TOOLS : activity;
}

// ── 活动短语：[进行时, 完成时] 两张说法，一并查表 ────────────────────────────────
function makePhraseOfActivity(): Map<string, string[]> {
  const table: Map<string, string[]> = new Map<string, string[]>();
  table.set(ACT_THINKING, ['正在分析请求', '已完成分析']);
  table.set(ACT_READ, ['正在读取文件', '已读取文件']);
  table.set(ACT_WRITE, ['正在写入文件', '已写入文件']);
  table.set(ACT_EDIT, ['正在编辑文件', '修改了文件']);
  table.set(ACT_SEARCH, ['正在搜索代码', '已搜索代码']);
  table.set(ACT_COMMANDS, ['正在运行命令', '执行了命令']);
  table.set(ACT_CODE, ['正在运行代码', '运行了代码']);
  table.set(ACT_WEB_SEARCH, ['正在搜索网页', '已搜索网页']);
  table.set(ACT_WEB_FETCH, ['正在访问网页', '已访问网页']);
  table.set(ACT_SUBAGENTS, ['正在协调子智能体', '已协调子智能体']);
  table.set(ACT_PLAN, ['正在更新计划', '更新了计划']);
  return table;
}

const PHRASE_OF_ACTIVITY: Map<string, string[]> = makePhraseOfActivity();
/** 认不出的活动：仍要说人话。 */
const PHRASE_OF_UNKNOWN: string[] = ['正在调用工具', '已调用工具'];

/** 活动的中文短语：closed 取完成时，否则进行时。 */
export function phraseOfActivity(activity: string, closed: boolean): string {
  const pair = PHRASE_OF_ACTIVITY.get(activity);
  const phrases: string[] = pair === undefined ? PHRASE_OF_UNKNOWN : pair;
  return closed ? phrases[PHRASE_DONE] : phrases[PHRASE_LIVE];
}

/** 组标题：按出现的活动种类拼接，两类用「并」连接（DSH 的 joinTwo）。 */
export function groupTitle(process: ChatLine[], closed: boolean): string {
  const activities: string[] = [];
  for (const line of process) {
    // 组里除了 thought/tool，还可能有「当时说过的话」（除答案以外的消息）——那些不是一步动作，
    // 不参与组头文案，所以显式跳过，而不是靠「非 thought 即 tool」的假设。
    if (line.kind !== 'thought' && line.kind !== 'tool') {
      continue;
    }
    const activity: string = line.kind === 'thought' ? ACT_THINKING : activityOfTool(line.name);
    if (activities.indexOf(activity) < 0) {
      activities.push(activity);
    }
  }
  if (activities.length === 0) {
    // 一组活动都没有：这一轮只说过几句话（组里除答案外没有思考也没有工具）。
    // 不兜底的话会落到下面「等」那一档，拼出「已调用工具、已调用工具、已调用工具等」这种
    // 根本不存在的过程——比没有标题更糟。
    return phraseOfActivity(ACT_THINKING, closed);
  }
  if (activities.length === 1) {
    return phraseOfActivity(activities[0], closed);
  }
  if (activities.length === 2) {
    return phraseOfActivity(activities[0], closed) + '并' + phraseOfActivity(activities[1], closed);
  }
  const parts: string[] = [];
  for (let i = 0; i < GROUP_TITLE_MAX_KINDS; i += 1) {
    parts.push(phraseOfActivity(activities[i], closed));
  }
  return parts.join('、') + '等';
}

/** 组里最典型的活动：决定组头图标。 */
export function groupActivity(process: ChatLine[]): string {
  for (let i = process.length - 1; i >= 0; i -= 1) {
    const line = process[i];
    if (line.kind === 'tool') {
      return activityOfTool(line.name);
    }
  }
  return ACT_THINKING;
}

/**
 * 组里的一行怎么画：'plain' 直接给文字，'step' 是一个可点开的步骤。
 *
 * 一轮里除答案以外的那些 assistant 消息也在组里（DSH 的成员口径），但它们不是「一步动作」，
 * 套一层可折叠标题会让人误以为那是工具调用。
 */
export function memberStyle(line: ChatLine): string {
  return line.kind === 'assistant' ? 'plain' : 'step';
}

/**
 * 正在跑时组头后面的那一截细节：最后一步在做什么（命令或参数的第一行）。
 * DSH 的 liveProcessDetail 只有标准与详细打开；精简档关着，组头就只报活动名。
 */
export function liveDetailOf(members: ChatLine[]): string {
  for (let i = members.length - 1; i >= 0; i -= 1) {
    const line = members[i];
    if (line.kind === 'tool') {
      const text = line.text === '' ? line.name : line.text;
      return text.length > 28 ? text.substring(0, 28) + '…' : text;
    }
    if (line.kind === 'assistant') {
      const first = line.text.split('\n')[0];
      return first.length > 28 ? first.substring(0, 28) + '…' : first;
    }
  }
  return '';
}

/** 一行该以哪种项出现。 */
export function kindOfLine(line: ChatLine): string {
  if (line.kind === 'thought') {
    return KIND_REASONING;
  }
  if (line.kind === 'tool') {
    return KIND_TOOL;
  }
  if (line.kind === 'error') {
    return KIND_ERROR;
  }
  if (line.kind === 'injection' || line.kind === 'checkpoint') {
    return KIND_INJECTION;
  }
  return KIND_MARKDOWN;
}

/**
 * 一行是否默认收起。
 *
 * 可折叠性只有 foldable 一处口径（thought/tool/injection/checkpoint）；error 与正文
 * 不可折叠，所以 error 永远可见——错误默认藏起来等于没报。
 */
export function collapsedOf(line: ChatLine, key: string, opened: Map<string, boolean>): boolean {
  if (!foldable(line.kind)) {
    return false;
  }
  return opened.get(key) !== true;
}

/** 过程行标题：已结束且不预览时只说「思考」，其余交给 lineTitle。 */
export function titleOfLine(line: ChatLine, closed: boolean, preview: boolean): string {
  if (line.kind === 'thought' && closed && !preview) {
    return '思考';
  }
  return lineTitle(line);
}

/**
 * 把 [from, to) 区间里的行按原序推进 out。
 *
 * 调用方只交「要单独成项的行」进来：折叠档里 user 由 itemsOf 自己放、过程行进组，
 * 这里拿到的就是正文/错误/注入这类各自成项的行。
 */
export function pushBodyLines(out: StreamItem[], lines: ChatLine[], from: number, to: number,
  closed: boolean, opened: Map<string, boolean>, preview: boolean): void {
  for (let i = from; i < to; i += 1) {
    const line = lines[i];
    const kind = kindOfLine(line);
    const key = 'b' + String(i);
    out.push({
      key: key, kind: kind, text: line.text,
      title: titleOfLine(line, closed, preview),
      closed: closed, process: [], activity: ACT_THINKING,
      closable: foldable(line.kind), collapsed: collapsedOf(line, key, opened),
      memberPreview: preview
    });
  }
}

/**
 * 把行切成该显示的项。
 *
 * 判定口径见文件头。runningStart 是正在跑的那一轮的起始下标（不 busy 时 -1）。
 */
export function itemsOf(lines: ChatLine[], policy: ChatPresentationPolicy,
  opened: Map<string, boolean>, runningStart: number): StreamItem[] {
  const out: StreamItem[] = [];
  let index = 0;
  while (index < lines.length) {
    const start = index;
    let end = start + 1;
    while (end < lines.length && lines[end].kind !== 'user') {
      end += 1;
    }
    const closed = start !== runningStart;
    let hasError = false;
    for (let i = start; i < end; i += 1) {
      if (lines[i].kind === 'error') {
        hasError = true;
      }
    }
    // 用户消息
    for (let i = start; i < end; i += 1) {
      if (lines[i].kind === 'user') {
        out.push({
          key: 'u' + String(i), kind: KIND_USER, text: lines[i].text, title: '',
          closed: closed, process: [], closable: false, collapsed: false, activity: ACT_THINKING,
          memberPreview: policy.settledReasoningPreview
        });
      }
    }

    const grouped = policy.stepGrouping === 'collapsed'
      || (policy.stepGrouping === 'history' && closed);
    // 能不能折：已结束的轮，或精简档里正在跑的这一轮；出错的轮一律摊开。
    const foldable = (closed || policy.foldWhileRunning) && !hasError;
    // 展开还是收起：精简档跑着也收起，标准/详细边跑边开，出错的摊开。
    const forceOpen = (!closed && !policy.foldWhileRunning) || hasError;

    // 这一轮的全部内容（用户消息除外），按原序。
    const members: ChatLine[] = [];
    for (let i = start; i < end; i += 1) {
      const line = lines[i];
      // 错误与注入不进组：错误要一眼看见，藏进一个已展开的组里等于没提。
      if (line.kind === 'user' || line.kind === 'injection' || line.kind === 'checkpoint' ||
        line.kind === 'error') {
        continue;
      }
      members.push(line);
    }
    // 答案 = 这一轮最后一次 assistant 消息。它留在组外一直可见（DSH 的 data-turn-process-answer:
    // 过程收起来，答案照旧露着）；折进组里的只有「过程」——更早的那些消息、思考、工具。
    let lastAssistant = -1;
    for (let i = members.length - 1; i >= 0; i -= 1) {
      if (members[i].kind === 'assistant') {
        lastAssistant = i;
        break;
      }
    }
    let hasProcess = false;
    for (let i = 0; i < members.length; i += 1) {
      if (i !== lastAssistant) {
        hasProcess = true;
        break;
      }
    }

    if (!grouped || !hasProcess) {
      // 全部档，或这一轮压根没有过程（只有一句回答）：按原序内联，不组建。
      for (let i = start; i < end; i += 1) {
        if (lines[i].kind !== 'user') {
          pushBodyLines(out, lines, i, i + 1, closed, opened, policy.settledReasoningPreview);
        }
      }
    } else {
      // 折叠档：整轮进一个组，组外不留东西。
      //
      // 这是 DSH 的口径（processSpec + compactAnswer）：已完成的轮在折叠态只占一行，
      // 答案也在组里；展开后组内按原序给出「更早的消息 → 思考 → 工具 → 答案」。
      // 我先前把答案一直留在组外，等于替读者决定了哪句算答案，且折叠态下正文孤零零挂在
      // 组下面，看起来既没折进去、时序也断了。
      // 组里只放过程；答案从 members 里摘出来，单独一项留在组外。
      const process: ChatLine[] = [];
      let answerIndex = -1;
      for (let i = start; i < end; i += 1) {
        if (lastAssistant >= 0 && members[lastAssistant] === lines[i]) {
          answerIndex = i;
          continue;
        }
        const kind = lines[i].kind;
        if (kind !== 'user' && kind !== 'injection' && kind !== 'checkpoint' && kind !== 'error') {
          process.push(lines[i]);
        }
      }
      const groupKey = 'g' + String(start);
      const openByHand = opened.get(groupKey) === true;
      const base = groupTitle(process, closed);
      const detail = (!closed && policy.liveProcessDetail) ? liveDetailOf(process) : '';
      out.push({
        key: groupKey, kind: KIND_GROUP, text: '',
        title: detail === '' ? base : base + '：' + detail,
        closed: closed, process: process,
        closable: foldable,
        collapsed: foldable && !openByHand && !forceOpen,
        activity: groupActivity(process),
        memberPreview: policy.settledReasoningPreview
      });
      // 组外：答案、错误、注入/压缩点，按原序。
      for (let i = start; i < end; i += 1) {
        const line = lines[i];
        if (i === answerIndex || line.kind === 'error' || line.kind === 'injection' ||
          line.kind === 'checkpoint') {
          pushBodyLines(out, lines, i, i + 1, closed, opened, policy.settledReasoningPreview);
        }
      }
    }
    index = end;
  }
  // next-input：最后一个已结束的过程组保持展开，等下一条输入才收。
  if (policy.collapseTiming === TIMING_NEXT_INPUT) {
    for (let i = out.length - 1; i >= 0; i -= 1) {
      if (out[i].kind === KIND_GROUP && out[i].closed) {
        out[i].collapsed = false;
        break;
      }
    }
  }
  return out;
}
// ── 增量计划：这一帧到底要更新哪几项 ────────────────────────────────────────
//
// 曾经的做法是「项数没变就只更新末项」，理由写的是「流式增量只落在尾巴」。这个前提是错的：
// 思考是原地追加到组里的行，而组并不在末尾（正文块跟在它后面），于是组永远不更新，
// 界面上只停着第一帧那一两个词，后面到达的全看不到。
//
// 摘要用「长度 + 首尾片段」而不是全文比较：每帧对整份 transcript 做全文比对是 O(总字数)，
// 而逐项摘要只有 O(项数)。之所以能靠摘要判定，是因为 ChatView 追加文本时总是 new 一个
// ChatLine 换掉数组元素，旧对象不被就地改写，所以上一帧的项与本帧的行不同源。
function digestOfText(text: string): string {
  const edge = 8;
  const head = text.length > edge ? text.substring(0, edge) : text;
  const tail = text.length > edge ? text.substring(text.length - edge) : text;
  return String(text.length) + ':' + head + ':' + tail;
}

/** 一项的可比较摘要：覆盖所有会影响渲染的字段，含组内每一行的内容。 */
export function itemDigest(item: StreamItem): string {
  const parts: string[] = [];
  parts.push(item.key);
  parts.push(item.kind);
  parts.push(item.title);
  parts.push(item.closed ? '1' : '0');
  parts.push(item.collapsed ? '1' : '0');
  parts.push(item.activity);
  parts.push(item.memberPreview ? '1' : '0');
  parts.push(digestOfText(item.text));
  for (const line of item.process) {
    parts.push(line.kind + '/' + line.name + '/' + digestOfText(line.text));
  }
  return parts.join('\u0001');
}

export interface ItemsPlan {
  /** 项数变了就只能整表替换：逐项更新对不上号。 */
  replaceAll: boolean;
  /** 只更新这些下标的项，升序。空数组表示这一帧什么都没变。 */
  updateIndexes: number[];
}

/**
 * 上一帧到本帧的差异计划。
 *
 * 只报「变了的那几项」而不是只报末项：一次 delta 可能只动中间的组（思考追加），
 * 也可能同时动组和正文（思考与正文交错到达）。
 */
export function planItems(prev: StreamItem[], next: StreamItem[]): ItemsPlan {
  if (prev.length !== next.length || prev.length === 0) {
    return { replaceAll: true, updateIndexes: [] };
  }
  const changed: number[] = [];
  for (let i = 0; i < next.length; i += 1) {
    if (itemDigest(prev[i]) !== itemDigest(next[i])) {
      changed.push(i);
    }
  }
  return { replaceAll: false, updateIndexes: changed };
}

/** FNV-1a：把 digest 压成短键，给列表键用。 */
function hashOf(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(36);
}

/**
 * 列表键必须带上它：LazyForEach 遇到同键会复用组件、不再重赋 @Prop，
 * 正文长了一截键却没变，界面就停在第一帧。键一变只重建这一项，其余项原地不动。
 */
export function itemVersion(item: StreamItem): string {
  return hashOf(itemDigest(item));
}

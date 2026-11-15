// 对话流渲染（按 docs/dsh-transcript-alignment.md 重写）。
//
// 三条硬约束来自 DSH：
//   1. 渲染单元是块（node），流式只动最后一项；
//   2. 过程组装「思考 + 工具」全部过程行，组头常驻，组内是次级内容；
//   3. 可见性在数据层决定——itemsOf 按档位与开合只产出该显示的项。
//
// 两份纯逻辑各有唯一实现，且都在 `.ts` 里、由 node --test 直接跑真代码：
//   行级语义（标题 / 展开正文 / 是否可折叠）→ model/Lines.ts
//   该显示哪些项（分组 / 折叠 / 组头文案）  → model/Items.ts
// 本文件只留下渲染与平台接口：StreamSource（IDataSource）、组头图标、StreamItemView。

import { ChatLine, lineDetail } from '../model/Lines';
import {
  ACT_CODE, ACT_COMMANDS, ACT_EDIT, ACT_PLAN, ACT_READ, ACT_SEARCH, ACT_SUBAGENTS, ACT_TOOLS,
  ACT_WEB_FETCH, ACT_WEB_SEARCH, ACT_WRITE, GROUP_HEADER_MIN, GROUP_HEADER_PAD, GROUP_MAX_HEIGHT,
  GROUP_RADIUS,
  KIND_ERROR, KIND_GROUP, KIND_INJECTION, KIND_REASONING, KIND_TOOL, KIND_USER,
  MONO_FAMILY, memberStyle, StreamItem, titleOfLine, TYPE_BODY, TYPE_MEDIUM, TYPE_MICRO, TYPE_SMALL, TYPE_TINY
} from '../model/Items';
import hilog from '@ohos.hilog';
import { Palette, RADIUS } from '../model/Palette';
import { MarkdownView } from './MarkdownView';
import { FollowBottom } from '../model/Follow';

/** LazyForEach 数据源：整体替换 + 单条更新。 */
export class StreamSource implements IDataSource {
  private items: StreamItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): StreamItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /**
   * 持有传入数组：调用方交出来之后就不得再改它（流式为省内存不做复制）。
   */
  replace(items: StreamItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  /** 流式只替换最后一项：已画好的项不重建。 */
  update(index: number, item: StreamItem): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    this.items[index] = item;
    for (const listener of this.listeners) {
      listener.onDataChange(index);
    }
  }

  /**
   * 返回内部数组引用，仅供比较（调用方不得修改，也不得持有后改写）。
   * 刻意不复制：流式每帧复制整个项数组是纯浪费。
   */
  snapshot(): StreamItem[] {
    return this.items;
  }
}

/**
 * 过程组头左侧的图标类别。
 *
 * 用枚举而不是裸数字：`$r()` 只接受编译期字面量，取图必须在渲染处写死，但「哪一类资源」
 * 应当有名字。工程里已验证可用的符号只有这几个，所以只映射到它们。
 */
enum GroupIcon {
  Bullet,
  Document,
  Command,
  Gear
}

function groupIconOf(activity: string): GroupIcon {
  if (activity === ACT_READ || activity === ACT_WEB_FETCH ||
    activity === ACT_WRITE || activity === ACT_EDIT) {
    return GroupIcon.Document;
  }
  if (activity === ACT_COMMANDS || activity === ACT_CODE) {
    return GroupIcon.Command;
  }
  if (activity === ACT_SEARCH || activity === ACT_WEB_SEARCH || activity === ACT_SUBAGENTS ||
    activity === ACT_PLAN || activity === ACT_TOOLS) {
    return GroupIcon.Gear;
  }
  return GroupIcon.Bullet;
}

@Component
export struct StreamItemView {
  /**
   * 这一行的数据。@ObjectLink 是响应式引用：流式时改写 row.text/row.process 就地重绘，
   * 不必换 key、也不必销毁重建（换 key 重建会让 MarkdownView 整段重解析，画面一直在闪）。
   */
  @Prop kind: string;
  @Prop text: string;
  @Prop title: string;
  @Prop closed: boolean;
  /**
   * 是否允许收起。开合态由 opened（@Link）在本组件内算，不吃 @Prop 的 collapsed：
   * LazyForEach 复用同 key 的组件时不会重新赋值 @Prop；@Link 是响应式引用，改了就必然重绘。
   */
  @Prop closable: boolean;
  @Prop itemKey: string;
  @Prop @Watch('onProcessChanged') process: ChatLine[];
  @Prop activity: string;
  /** 静止的过程行标题是否带首行预览（DSH 的 settledReasoningPreview，精简档为 false）。 */
  @Prop memberPreview: boolean;

  @Prop dark: boolean;

  /** 展开组自己的滚动器：组内内容按同一套规则决定是否跟着到底。 */
  private groupScroller: Scroller = new Scroller();
  private groupFollow: FollowBottom = new FollowBottom();
  @Prop palette: Palette;
  @Link opened: Map<string, boolean>;
  @State private hovered: boolean = false;

  private isOpen(key: string): boolean {
    return this.opened.get(key) === true;
  }

  /**
   * 组内成员行的开合：只认手动展开表，不看 closable。
   * 用 open() 会出事——运行中的组 closable=false，于是组里每一行都被当成「永久展开」，
   * 步骤标题下面又摊一遍明细（截图里那一串重复的 The / {...} / pong:ping）。
   */
  private isOpenAt(key: string, memberRow: boolean): boolean {
    return memberRow ? this.isOpen(key) : this.open(key);
  }

  /** 这一项此刻是否展开：不可收起的恒展开，可收起的看手动展开表。 */
  private open(key: string): boolean {
    return !this.closable || this.isOpen(key);
  }

  /** 组内内容变长：跟随中就把阅读位置留在底部，读者上翻过就别动它。 */
  onProcessChanged(): void {
    if (!this.groupFollow.follows() || !this.open(this.itemKey)) {
      return;
    }
    setTimeout(() => {
      if (!this.groupFollow.follows()) {
        return;
      }
      try {
        this.groupFollow.beginProgrammatic();
        this.groupScroller.scrollEdge(Edge.Bottom);
        setTimeout(() => {
          this.groupFollow.endProgrammatic();
        }, 120);
      } catch (e) {
        this.groupFollow.endProgrammatic();
      }
    }, 32);
  }

  private flip(key: string): void {
    const next: Map<string, boolean> = new Map();
    this.opened.forEach((value: boolean, at: string) => {
      next.set(at, value);
    });
    const open: boolean = !this.isOpen(key);
    next.set(key, open);
    this.opened = next;
    hilog.info(0x0000, 'hvoltide', 'flip: %{public}s -> %{public}s', key, String(open));
  }

  /**
   * 可折叠行的标题行：箭头 + 标题，整行可点。
   *
   * mono 的两种字号/字体不同，所以按 mono 走两条 Text（不给非等宽行硬塞 fontFamily，
   * 免得写一个不存在的字体族）。@Builder 里不能声明局部量，值都由调用处算好传入。
   */
  @Builder
  CollapsibleHeader(headerKey: string, titleOpen: string, titleClosed: string, fontSize: number,
    mono: boolean, tint: string, memberRow: boolean = false) {
    // 开合态在这里用 this.open(headerKey) 现算，不靠参数传进来：@Builder 的参数是调用时的
    // 快照，状态变了它不重新求值——传 open 进来会得到「箭头不动、正文却伸出去」的错位。
    // 两个标题也由调用处分别算好（它们本身不依赖开合），这里只按开合挑一个。
    Row({ space: 5 }) {
      SymbolGlyph(this.isOpenAt(headerKey, memberRow)
        ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
        .fontSize(TYPE_MICRO)
        .fontColor([this.palette.textTertiary])
      if (mono) {
        Text(this.isOpenAt(headerKey, memberRow) ? titleOpen : titleClosed)
          .fontSize(fontSize)
          .fontFamily(MONO_FAMILY)
          .fontColor(tint)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text(this.isOpenAt(headerKey, memberRow) ? titleOpen : titleClosed)
          .fontSize(fontSize)
          .fontColor(tint)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .onClick(() => {
      this.flip(headerKey);
    })
  }

  /** 组头左侧：收起时是活动图标（悬停换成箭头），展开时是箭头——DSH 的 DisclosureRow。 */
  @Builder
  GroupLeading(icon: GroupIcon) {
    // 展开时给向下箭头（点它收起），悬停时也给箭头（暗示这行可点），其余时候给活动图标。
    if (this.open(this.itemKey) || this.hovered) {
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(TYPE_SMALL)
        .fontColor([this.palette.textTertiary])
    } else if (icon === GroupIcon.Document) {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(TYPE_BODY)
        .fontColor([this.palette.textTertiary])
    } else if (icon === GroupIcon.Command) {
      SymbolGlyph($r('sys.symbol.hammer_fill'))
        .fontSize(TYPE_BODY)
        .fontColor([this.palette.textTertiary])
    } else if (icon === GroupIcon.Gear) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(TYPE_BODY)
        .fontColor([this.palette.textTertiary])
    } else {
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(TYPE_BODY)
        .fontColor([this.palette.textTertiary])
    }
  }

  /**
   * 组内的一行过程：标题 + 展开正文。
   *
   * 开合键由 ForEach 处按位置算好传入（@Builder 里不能声明局部量）。刻意不用内容派生的键：
   * 那种键含正文长度，流式追加时每来一个 token 就变一次，用户点开的思考行会自己收起；
   * 而组内成员只会原地追加、不在组内插行，位置键跨重建稳定。
   */
  @Builder
  ProcessLine(line: ChatLine, memberKey: string) {
    if (memberStyle(line) === 'plain') {
      // 组内的过程消息（这一轮里除答案以外的那些话）：直接给文字。
      // 它不是一步动作，套一层「点开看」的标题只会让人以为是工具调用。
      MarkdownView({ text: line.text, dark: this.dark, baseSize: TYPE_TINY, muted: true })
    } else {
      // preview 只在收起时给：展开后正文就在下面，标题再带一遍摘要就是同一句话印两遍。
      this.CollapsibleHeader(memberKey, titleOfLine(line, this.closed, false),
        titleOfLine(line, this.closed, this.memberPreview), TYPE_TINY, true,
        this.palette.textTertiary, true)
      if (this.isOpen(memberKey)) {
        MarkdownView({ text: lineDetail(line), dark: this.dark, baseSize: TYPE_TINY, muted: true })
      }
    }
  }

  build() {
    Column({ space: 4 }) {
      if (this.kind === KIND_USER) {
        Row() {
          Text(this.text)
            .fontSize(TYPE_BODY)
            .fontColor(this.palette.textPrimary)
            .backgroundColor(this.palette.pane)
            .borderRadius(RADIUS)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .maxLines(20)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      } else if (this.kind === KIND_GROUP) {
        // 组头：图标/箭头 + 标题。整行可点。
        Row({ space: 6 }) {
          this.GroupLeading(groupIconOf(this.activity))
          Text(this.title)
            .fontSize(TYPE_MEDIUM)
            .fontColor(this.palette.textTertiary)
            .opacity(this.closed ? 0.85 : 1)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        // 不写死高度：固定 24px 会让文字溢出到热区之外，点标题中下部落空。
        // 用最小高度 + 上下内边距，热区与看到的那一行一致。
        .constraintSize({ minHeight: GROUP_HEADER_MIN })
        .padding({ top: GROUP_HEADER_PAD, bottom: GROUP_HEADER_PAD })
        .onHover((hover: boolean) => {
          this.hovered = hover;
        })
        .onClick(() => {
          this.flip(this.itemKey);
        })

        if (this.open(this.itemKey)) {
          // 展开的组限高内滚：DSH 的 capped 就是这个作用——步骤多起来时整条对话不该被顶走。
          // （之前 141 的高度的确太小；这里放宽到 GROUP_MAX_HEIGHT，并让内容自己滚。）
          Scroll(this.groupScroller) {
            Column({ space: 8 }) {
            ForEach(this.process, (line: ChatLine, at: number) => {
              this.ProcessLine(line, this.itemKey + ':' + String(at))
            }, (line: ChatLine, at: number) => this.itemKey + ':' + String(at))
          }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 12 })
          }
          .width('100%')
          .constraintSize({ maxHeight: GROUP_MAX_HEIGHT })
          .scrollBar(BarState.Off)
          .onScrollStart(() => {
            this.groupFollow.onScrollStart();
          })
          .onScrollStop(() => {
            this.groupFollow.onScrollStop(this.groupScroller.isAtEnd());
          })
          .margin({ top: 4 })
          .backgroundColor(this.palette.pane)
          .borderRadius(GROUP_RADIUS)
        }
      } else if (this.kind === KIND_TOOL || this.kind === KIND_REASONING || this.kind === KIND_ERROR ||
        this.kind === KIND_INJECTION) {
        // 错误行的标题用 fail 色：它和普通过程行不是一类东西。
        // 行标题与开合无关，两个标题传同一个；开合态由 Builder 内部现算。
        this.CollapsibleHeader(this.itemKey, this.title, this.title, TYPE_SMALL,
          false, this.kind === KIND_ERROR ? this.palette.fail : this.palette.textTertiary)
        if (this.open(this.itemKey)) {
          MarkdownView({ text: this.text, dark: this.dark })
        }
      } else {
        MarkdownView({ text: this.text, dark: this.dark })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
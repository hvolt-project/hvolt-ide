// The chat surface: a transcript of blocks, with process folded according to the reader's mode.

import hilog from '@ohos.hilog';
import { GAP, glassEdge, palette, Palette } from '../model/Palette';

import { ChatLine } from '../model/Lines';
import { appendLine } from '../model/ChatView';
import { itemVersion, itemsOf, planItems, StreamItem } from '../model/Items';
import { StreamItemView, StreamSource } from './ChatStream';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { applySuggestion, suggestFor, Suggestion } from '../model/Complete';
import { readTodos, TodoViewItem } from '../harness/tools/Todo';
import { ChatPresentationPolicy, collapseTimingOf, presentationPolicyFor, viewModeOf } from '../model/Policy';
import { AskAnswer, AskOption, AskQuestion, progressLabel } from '../model/Ask';
import { composerAction } from '../model/Composer';
import { FollowBottom } from '../model/Follow';


export { ChatKind, ChatLine } from '../model/Lines';

export interface ChatActions {
  send: (text: string, images: string[]) => void;
  stop: () => void;
  reset: () => void;
  /** Compiles the older part of the conversation now, without waiting for the trigger line. */
  compact: () => void;
  /** Answers the question on screen: chosen labels plus optional free text. */
  answerAsk: (selected: string[], custom: string) => void;
  /** Declines the remaining questions of the current call. */
  cancelAsk: () => void;
  /** Lists the skill catalog in the transcript. */
  listSkills: () => void;
  close: () => void;
}

/** 面板展开时最多画几行。 */
const TODO_SHOW: number = 6;
/** 展开态的最高高度：它浮在对话上方，超过这个高度就内滚，免得顶掉对话区。 */
const TODO_PANEL_MAX: number = 200;

@Component
export struct ChatPanel {
  @Prop dark: boolean = true;
  /** Project name is the headline; the endpoint identity sits under it. */
  @Prop project: string = '';
  @Prop statTurns: number = 0;
  @Prop statSteps: number = 0;
  @Prop statTokens: number = 0;
  @Prop statCache: number = -1;
  @Prop statPressure: number = 0;
  /**
   * 工作步骤展示档位。切档会改变 itemsOf 的产出（分组与可见性），所以必须挂 @Watch：
   * 只更新属性不重算 items，切档在界面上就是没反应。
   */
  @Prop @Watch('onItemsInputChanged') viewMode: string = 'compact';
  /** 折叠时机同样参与 itemsOf 的判定（next-input），切它也需重算。 */
  @Prop @Watch('onItemsInputChanged') collapseTiming: string = 'immediate';
  @Prop statContext: number = 0;
  @Prop statRate: number = 0;
  /** A question a tool is waiting on; '' when nothing is pending. */
  /** Questions a tool is waiting on, and which one is on screen. */
  @Prop askQuestions: AskQuestion[] = [];
  @Prop askIndex: number = 0;
  /** Choices made so far for the question on screen, by option label. */
  @State askPicked: string[] = [];
  @Prop askAnswers: AskAnswer[] = [];
  @State askCollapsed: boolean = false;
  @State askCustom: string = '';
  @Prop provider: string = '';
  @Prop model: string = '';
  /** Project files, for @ completion. */
  @Prop files: string[] = [];
  // The same figures the editor's status row shows, fed from the one session: the transcript and
  // the numbers under it belong to the same surface, so they are one component, not two copies.
  @Link @Watch('onLinesChanged') lines: ChatLine[];
  /**
   * 是否在跑。它决定 runningTurnStart，进而决定末轮是「运行中」还是「已结束」——
   * 所以开始/结束也要重算 items，否则组会一直停在旧的开合状态。
   */
  @Link @Watch('onItemsInputChanged') busy: boolean;
  actions: ChatActions = {
    send: () => {
    },
    stop: () => {
    },
    reset: () => {
    },
    close: () => {
    }
  };
  @State private draft: string = '';
  /** 输入框有焦点即键盘弹起；focus/blur 是可靠的，keyboardHeightChange 收起时不发 0。 */
  @State private keyboardUp: boolean = false;
  /** Completion slate shown above the input while the draft starts with / or @. */
  @State private suggest: string[] = [];
  @State private suggestKind: string = '';
  @State private asrActive: boolean = false;
  /** Attachments for the next message, as data URLs. */
  @State private attachments: string[] = [];
  // Loaded on first use: the speech kit is absent from this SDK, and a static import would
  // take the whole panel down with it.
  private asr: ESObject = null;
  private scroller: Scroller = new Scroller();
  /**
   * 吸底状态。主列表与展开的过程组共用同一套规则（model/Follow.ts）：
   * 只有手指的滚动能改变它，程序自己滚不算。
   */
  private follow: FollowBottom = new FollowBottom();
  /** 已经排了一次滚底：流式期间不要再排队。 */
  private scrollPending: boolean = false;
  /** Pending long-press on the field; -1 means the hold already became dictation. */
  private holdTimer: number = -1;
  /** Draft text before dictation, so interim results do not stack up. */
  /** The reader's own open/closed choices; they outlive a mode switch. */
  /** 每一行自己的开合，键是行下标；与 DSH 的 DisclosureRow 一样逐行管，不分档位。 */
  /**
   * 开合状态。它必须驱动 items 重算：collapsed 是 itemsOf 按 opened 算出来的，
   * 只改 opened 不重算 items，点组头就没有任何反应。
   */
  @State @Watch('onItemsInputChanged') opened: Map<string, boolean> = new Map();
  /** LazyForEach 的数据源：粒度是块，流式只更新最后一项。 */
  private source: StreamSource = new StreamSource();
  /** 待办清单：模型用 todo_write 写，这里只读并画出来。 */
  @State private todos: TodoViewItem[] = [];
  /** 默认收起：面板常驻标题下，展开态只在读者要看全部步骤时才出现。 */
  @State private todoOpen: boolean = false;

  /**
   * 档位/时机、开合、跑与停三者的共同重算入口：它们都可能改变任意一项
   * （分组的可见性、某一项的开合、末轮是「运行中」还是「已结束」），
   * 所以都不能走「只更新末项」的快路径。
   */
  onItemsInputChanged(): void {
    this.applyItems();
  }

  onLinesChanged(): void {
    this.applyItems();
    const last: ChatLine | null = this.lines.length > 0 ? this.lines[this.lines.length - 1] : null;
    // 待办只由 todo_write 改：那一行出现时重读，别在每帧流式增量里读文件。
    if (last !== null && last.kind === 'tool' && last.name.startsWith('todo')) {
      this.refreshTodos();
    }
    if (last !== null && last.kind === 'user') {
      // 新的一轮开始：读者刚发话，回到跟随。
      this.follow.reset();
    }
    // 手指正在拖动就不再吸底：否则新到的 token 会把读者刚翻上去的位置拽回底部。
    if (!this.follow.follows()) {
      return;
    }
    // 流式时每个 token 都会走到这里：只允许排一次滚底，否则一串延时排起来，画面在两次布局之间
    // 被反复拉到底，看着就是「文字固定在底部不停刷新」。
    if (this.scrollPending) {
      return;
    }
    this.scrollPending = true;
    // After the frame that added the row: scrolling before layout has grown the list reaches the
    // old bottom and stops short of the new last line.
    setTimeout(() => {
      this.scrollPending = false;
      // 定时器触发的这一刻读者可能已经开始上翻，按排程时的判断执行会把他拽回底部。
      if (!this.follow.follows()) {
        return;
      }
      try {
        this.follow.beginProgrammatic();
        this.scroller.scrollEdge(Edge.Bottom);
        setTimeout(() => {
          this.follow.endProgrammatic();
        }, 120);
      } catch (e) {
        this.follow.endProgrammatic();
      }
    }, 32);
  }

  private endpointLabel(): string {
    const host = this.provider.length > 0 ? this.provider : '未配置';
    const model = this.model.length > 0 ? this.model : '—';
    return host + ' · ' + model;
  }

  private p(): Palette {
    return palette(this.dark);
  }

  /** Picks images and inlines them as data URLs, so a message is self-contained. */
  private async pickImages(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const picked = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 4
      });
      if (picked.photoUris === undefined || picked.photoUris.length === 0) {
        return;
      }
      const added: string[] = this.attachments.slice();
      for (const uri of picked.photoUris) {
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        let bytes: Uint8Array;
        try {
          bytes = new Uint8Array(fs.statSync(file.fd).size);
          fs.readSync(file.fd, bytes.buffer);
        } finally {
          fs.closeSync(file);
        }
        const encoder = new util.Base64Helper();
        const b64 = encoder.encodeToStringSync(bytes);
        const mime = uri.toLowerCase().includes('.png') ? 'image/png' : 'image/jpeg';
        added.push('data:' + mime + ';base64,' + b64);
      }
      this.attachments = added;
    } catch (e) {
      this.showToast('选图失败：' + (e as Error).message);
    }
  }

  private startDictation(): void {
    // Dictation starts a fresh message: over existing text it would have to decide whether to
    // append, replace or merge, and any of those is worse than asking for an empty field.
    if (this.busy || this.asrActive || this.draft.trim().length > 0) {
      return;
    }
    // The speech kit is absent from the SDK this app builds against, and merely referencing its
    // module aborts the process, so dictation is reported unavailable rather than attempted.
    this.showToast('语音识别不可用：本机没有语音组件');
  }

  private stopDictation(): void {
    if (!this.asrActive) {
      return;
    }
    this.asrActive = false;
    if (this.asr !== null) {
      this.asr.stop();
    }
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  /** Completes the token being typed: commands after /, project files after @. */
  private refreshSuggest(draft: string): void {
    const found: Suggestion = suggestFor(draft, this.files);
    this.suggestKind = found.kind;
    this.suggest = found.items;
  }

  private commandHint(item: string): string {
    if (item === '/reset') {
      return '清空这段对话';
    }
    if (item === '/compact') {
      return '立即压缩较早的对话';
    }
    if (item === '/skills') {
      return '列出可用技能';
    }
    if (item === '/help') {
      return '显示可用命令与引用方式';
    }
    return '';
  }

  private accept(item: string): void {
    this.draft = applySuggestion(this.draft, this.suggestKind, item);
    this.suggest = [];
    this.suggestKind = '';
  }

  /** Slash commands are ordinary text until sent; nothing opens a separate mode. */
  /** 回合在跑、且输入框里没有字：这时按钮才是「终止」。判定本身在 model/Composer.ts，可测。 */
  private stopping(): boolean {
    return composerAction(this.busy, this.draft) === 'stop';
  }

  private submit(): void {
    const text = this.draft.trim();
    if (text.length === 0) {
      return;
    }
    // 忙时发出去的是「打断并插话」：回合还在跑，先停掉它，再把这句话作为新输入送上去。
    // 所以这里不再因为 busy 就 return——那样会让输入框里的字发不出去。
    this.draft = '';
    if (text === '/reset') {
      this.confirmClear();
      return;
    }
    if (text === '/compact') {
      this.actions.compact();
      return;
    }
    if (text === '/skills') {
      this.actions.listSkills();
      return;
    }
    if (this.askQuestions.length > 0) {
      // Free text is the answer: a label alone cannot carry a correction or a reason.
      this.actions.answerAsk([], text);
      this.askPicked = [];
      return;
    }
    // Attachments belong to the message being sent; leaving them out here was what made
    // `images` undefined and blew up in toWire.
    const images = this.attachments;
    this.attachments = [];
    this.actions.send(text, images);
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空这段对话？',
      message: '对话记录会从这台设备上删除，无法恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#E5484D',
        action: () => {
          this.actions.reset();
        }
      }
    });
  }

  /** 启动时读一次：昨天写下的清单在重启后照样是这一面的一部分。 */
  aboutToAppear(): void {
    this.refreshTodos();
  }


  /** 展开时最多画几行，其余折成「+ N 条」。 */
  private todoVisible(): TodoViewItem[] {
    return this.todos.slice(0, TODO_SHOW);
  }

  /** 状态图标用系统符号：对勾、实心圆、虚线圆。 */
  @Builder
  TodoMark(status: string) {
    SymbolGlyph(status === 'completed' ? $r('sys.symbol.checkmark')
      : (status === 'in_progress' ? $r('sys.symbol.circle') : $r('sys.symbol.circle_dashed')))
      .fontSize(14)
      .fontColor([status === 'completed' ? this.p().textTertiary
        : (status === 'in_progress' ? this.p().brand : this.p().divider)])
  }

  /** 收起时那一行摘要：正在做的优先，否则第一条还没做的。 */
  private todoSummary(): string {
    for (const item of this.todos) {
      if (item.status === 'in_progress') {
        return item.content;
      }
    }
    for (const item of this.todos) {
      if (item.status !== 'completed') {
        return item.content;
      }
    }
    return this.todos.length > 0 ? this.todos[0].content : '';
  }

  private policy(): ChatPresentationPolicy {
    const base: ChatPresentationPolicy = presentationPolicyFor(viewModeOf(this.viewMode));
    // 折叠时机与档位正交：档位表给的是默认值（恒 immediate），界面上的选择必须覆盖它，
    // 否则「下一条输入时」这个选项写进了状态、也挂了 @Watch，却到不了 itemsOf。
    base.collapseTiming = collapseTimingOf(this.collapseTiming);
    return base;
  }

  /** 正在跑的 turn 的起始下标；不 busy 时返回 -1。 */
  private runningTurnStart(): number {
    if (!this.busy) {
      return -1;
    }
    for (let i = this.lines.length - 1; i >= 0; i -= 1) {
      if (this.lines[i].kind === 'user') {
        return i;
      }
    }
    return -1;
  }

  private applyItems(): void {
    const items = itemsOf(this.lines, this.policy(), this.opened, this.runningTurnStart());
    // 一律走逐项更新，绝不因为「开合/档位/跑停变了」就整表替换。
    //
    // LazyForEach 的两个回调不等价：onDataChange 会刷新那一项，而 onDataReloaded 之后
    // key 相同的项会被复用，@Prop 不会再赋一次值。开合状态恰好是 @Prop，于是「点组头→
    // 重算→replace」这条路走完什么都不变。项数变了才只能替换（planItems 会这么报）。
    // 逐项读数：折叠对不对只能靠这个看，界面截图看不出 closed/closable 是哪个错了。
    const marks: string[] = [];
    for (const item of items) {
      marks.push(item.kind + (item.kind === 'markdown' ? '(' + String(item.text.length) + ')' : '') +
        (item.closed ? '/closed' : '/live') +
        (item.closable ? '/foldable' : '/fixed') + (item.collapsed ? '/collapsed' : '/open') +
        (item.key.startsWith('g') ? '@' + item.key : ''));
    }
    hilog.info(0x0000, 'hvoltide', 'items state: mode=%{public}s grouping=%{public}s | %{public}s',
      this.viewMode, this.policy().stepGrouping, marks.join(' | '));
    const plan = planItems(this.source.snapshot(), items);
    if (plan.replaceAll) {
      this.source.replace(items);
      hilog.info(0x0000, 'hvoltide', 'items: %{public}d from %{public}d lines',
        items.length, this.lines.length);
      return;
    }
    // 行级刷新：只更新变化的下标，其余行（折叠的历史轮、用户气泡、待办条）不重建。
    // 列表键里带 itemVersion，所以正在长的那一行会被重建；折叠中的组头行在其成员变化时
    // 也随之刷新，展开后看到的是最新内容——对应 DSH 里「折叠不影响订阅」那一条。
    for (const at of plan.updateIndexes) {
      this.source.update(at, items[at]);
    }
    if (plan.updateIndexes.length > 0) {
      hilog.info(0x0000, 'hvoltide', 'items: updated %{public}d/%{public}d',
        plan.updateIndexes.length, items.length);
    }
  }

  private refreshTodos(): void {
    try {
      this.todos = readTodos();
    } catch (e) {
      this.todos = [];
    }
  }

  /** 已完成条数，用于标题上的计数。 */
  private todosDone(): number {
    let done = 0;
    for (const item of this.todos) {
      if (item.status === 'completed') {
        done += 1;
      }
    }
    return done;
  }

  private isOpen(key: string): boolean {
    return this.opened.get(key) === true;
  }

  private flip(key: string): void {
    const next: Map<string, boolean> = new Map();
    this.opened.forEach((value: boolean, at: string) => {
      next.set(at, value);
    });
    next.set(key, !this.isOpen(key));
    this.opened = next;
  }

  /** 最后一个已结束 turn 的下标（next-input 时让它保持展开）。 */
  /** 最后一个已结束项的下标（next-input 时让过程组保持展开）。 */
  private lastClosedIndex(): number {
    const items = this.source.snapshot();
    for (let i = items.length - 1; i >= 0; i -= 1) {
      if (items[i].closed) {
        return i;
      }
    }
    return -1;
  }


  private current(): AskQuestion {
    if (this.askIndex >= 0 && this.askIndex < this.askQuestions.length) {
      return this.askQuestions[this.askIndex];
    }
    return { id: '', question: '', header: '', options: [], multiSelect: false };
  }

  private askText(): string {
    return this.current().question;
  }

  private askHeaderOf(): string {
    return this.current().header;
  }

  private askOptionsOf(): AskOption[] {
    return this.current().options;
  }

  private askMultiOf(): boolean {
    return this.current().multiSelect;
  }

  /** 已答过的题：一行一条，只读。 */
  private answeredLines(): string[] {
    const out: string[] = [];
    for (const answer of this.askAnswers) {
      const picked = answer.selected.join('、');
      let text = picked;
      if (answer.custom.length > 0) {
        text = picked.length > 0 ? picked + '（' + answer.custom + '）' : answer.custom;
      }
      out.push(text.length === 0 ? '跳过' : text);
    }
    return out;
  }

  /** 提交当前题：勾选项加自由输入一起去，空提交等于跳过。 */
  private submitAnswer(): void {
    this.actions.answerAsk(this.askPicked, this.askCustom);
    this.askPicked = [];
    this.askCustom = '';
  }

  private progress(): string {
    return progressLabel(this.askIndex, this.askQuestions.length);
  }

  /**
   * chat 面自己的状态行：只属于这一面，与 IDE 底部那条无关。
   *
   * 单行三段，无背景无圆角：左段仪表图标＋轮次步数与速率，中段硬盘图标＋累计用量与缓存命中，
   * 右段圆环＋上下文占用。中段吃掉剩余宽度并在放不下时省略，左右两段不压缩，
   * 这样 1316px 下三段都能留在屏内。
   */
  @Builder
  StatusBar() {
    Row({ space: 6 }) {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.gauge_with_dots_needle_33percent'))
          .fontSize(11)
          .fontColor([this.p().textTertiary])
        Text(this.progressText())
          .fontSize(10)
          .fontColor(this.p().textTertiary)
          .maxLines(1)
      }
      .flexShrink(0)

      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.externaldrive'))
          .fontSize(11)
          .fontColor([this.p().textTertiary])
        Text(this.costText())
          .fontSize(10)
          .fontColor(this.p().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .margin({ left: 6 })

      if (this.statPressure > 0) {
        Row({ space: 4 }) {
          Progress({ value: this.statPressure, total: 100, type: ProgressType.Ring })
            .width(12)
            .height(12)
            .color(this.p().brand)
            .style({ strokeWidth: 2 })
          Text(Math.round(this.statPressure) + '%')
            .fontSize(10)
            .fontColor(this.p().textTertiary)
            .maxLines(1)
        }
        .flexShrink(0)
        .margin({ left: 6 })
      }
    }
    .width('100%')
    .height(28)
    .padding({ left: 12, right: 12 })
  }

  private progressText(): string {
    const parts: string[] = [this.statTurns + ' 轮 ' + this.statSteps + ' 步'];
    if (this.statRate > 0) {
      parts.push(this.statRate >= 100 ? Math.round(this.statRate) + ' tok/s'
        : this.statRate.toFixed(1) + ' tok/s');
    }
    return parts.join(' · ');
  }

  private costText(): string {
    const million = this.statTokens / 1000000;
    const amount = million >= 1 ? million.toFixed(1) + 'M'
      : this.statTokens >= 1000 ? (this.statTokens / 1000).toFixed(1) + 'K' : '' + this.statTokens;
    // 环已经表达「本」次占用（当前 prompt / 窗口），这里只留累计计费与缓存命中，
    // 否则三段文字加起来又把环挤出屏幕。
    const parts: string[] = [amount + ' tok'];
    if (this.statCache >= 0) {
      parts.push('缓存命中 ' + Math.round(this.statCache) + '%');
    }
    return parts.join(' · ');
  }

  @Builder
  Composer() {
    Column({ space: 6 }) {
      if (this.suggest.length > 0) {
        List({ space: 0 }) {
          ForEach(this.suggest, (item: string) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(this.suggestKind === 'cmd' ? item : '@' + item)
                  .fontSize(13)
                  .fontColor(this.p().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                if (this.suggestKind === 'cmd') {
                  Text(this.commandHint(item))
                    .fontSize(11)
                    .fontColor(this.p().textTertiary)
                }
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .onClick(() => {
                this.accept(item);
              })
            }
          }, (item: string) => this.suggestKind + ':' + item)
        }
        .width('100%')
        .constraintSize({ maxHeight: 208 })
        .backgroundColor(this.p().card)
        .borderRadius(12)
      }

      if (this.attachments.length > 0) {
        Row({ space: 8 }) {
          ForEach(this.attachments, (image: string, index: number) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              Image(image)
                .width(52)
                .height(52)
                .borderRadius(8)
                .objectFit(ImageFit.Cover)
              Text('\u00d7')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .width(18)
                .height(18)
                .textAlign(TextAlign.Center)
                .backgroundColor('#00000088')
                .borderRadius(9)
                .onClick(() => {
                  const next: string[] = this.attachments.slice();
                  next.splice(index, 1);
                  this.attachments = next;
                })
            }
          }, (image: string, index: number) => index + ':' + image.length)
        }
        .width('100%')
      }

      if (this.askQuestions.length > 0) {
        Column({ space: 10 }) {
          // 眉标：谁在问、第几题、收起/展开
          Row({ space: 8 }) {
            Text(this.askHeaderOf().length > 0 ? this.askHeaderOf() : '待你决定')
              .fontSize(11)
              .fontColor(this.p().textTertiary)
              .layoutWeight(1)
            if (this.askQuestions.length > 1) {
              Text(this.progress())
                .fontSize(11)
                .fontColor(this.p().textTertiary)
            }
            Text(this.askCollapsed ? '展开' : '收起')
              .fontSize(11)
              .fontColor(this.p().textTertiary)
              .onClick(() => {
                this.askCollapsed = !this.askCollapsed;
              })
          }
          .width('100%')

          if (!this.askCollapsed) {
            // 答过的题留在卡里，变成只读的一行
            ForEach(this.answeredLines(), (line: string, index: number) => {
              Row({ space: 6 }) {
                Text('已答')
                  .fontSize(11)
                  .fontColor(this.p().textTertiary)
                Text(line)
                  .fontSize(12)
                  .fontColor(this.p().textSecondary)
                  .layoutWeight(1)
                  .maxLines(2)
              }
              .width('100%')
            }, (line: string, index: number) => index + ':' + line)

            Text(this.askText())
              .fontSize(15)
              .fontColor(this.p().textPrimary)
              .width('100%')

            ForEach(this.askOptionsOf(), (option: AskOption) => {
              Row({ space: 10 }) {
                Stack() {
                  // 图形即模式：单选画圆，多选画方框，选中的标记也不同（圆点 / 勾）。
                  if (this.askMultiOf()) {
                    Rect({ width: 16, height: 16 })
                      .radius(4)
                      .fill(this.askPicked.indexOf(option.label) >= 0
                        ? this.p().brandSoft : this.p().bg)
                      .stroke(this.askPicked.indexOf(option.label) >= 0
                        ? this.p().brand : this.p().divider)
                      .strokeWidth(1.5)
                  } else {
                    Circle({ width: 16, height: 16 })
                      .fill(this.askPicked.indexOf(option.label) >= 0
                        ? this.p().brandSoft : this.p().bg)
                      .stroke(this.askPicked.indexOf(option.label) >= 0
                        ? this.p().brand : this.p().divider)
                      .strokeWidth(1.5)
                  }
                  if (this.askPicked.indexOf(option.label) >= 0) {
                    if (this.askMultiOf()) {
                      Text('✓')
                        .fontSize(11)
                        .fontColor(this.p().brand)
                    } else {
                      Circle({ width: 7, height: 7 })
                        .fill(this.p().brand)
                    }
                  }
                }
                .width(16)
                .height(16)

                Column({ space: 3 }) {
                  Text(option.label)
                    .fontSize(14)
                    .fontColor(this.p().textPrimary)
                    .width('100%')
                  if (option.description.length > 0) {
                    Text(option.description)
                      .fontSize(12)
                      .fontColor(this.p().textSecondary)
                      .width('100%')
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding(12)
              .backgroundColor(this.askPicked.indexOf(option.label) >= 0
                ? this.p().brandSoft : this.p().bg)
              .borderRadius(10)
              .onClick(() => {
                // 点选只改选择，提交由下面的按钮决定：点一下就提交没有反悔余地。
                const at = this.askPicked.indexOf(option.label);
                if (!this.askMultiOf()) {
                  this.askPicked = at >= 0 ? [] : [option.label];
                  return;
                }
                const next: string[] = this.askPicked.slice();
                if (at >= 0) {
                  next.splice(at, 1);
                } else {
                  next.push(option.label);
                }
                this.askPicked = next;
              })
            }, (option: AskOption, index: number) => index + ':' + option.label)

            TextInput({ placeholder: '也可以直接写你要的', text: this.askCustom })
              .fontSize(13)
              .fontColor(this.p().textPrimary)
              .placeholderColor(this.p().textTertiary)
              .backgroundColor(this.p().bg)
              .borderRadius(8)
              .width('100%')
              .height(36)
              .onChange((value: string) => {
                this.askCustom = value;
              })
              .onSubmit(() => {
                this.submitAnswer();
              })

            Row({ space: 10 }) {
              // 两种模式都常驻提交按钮：选择与提交分开，选错了还能改。
              Text('提交')
                .fontSize(13)
                .fontColor(this.askPicked.length > 0 || this.askCustom.length > 0
                  ? this.p().brand : this.p().textTertiary)
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(8)
                .backgroundColor(this.askPicked.length > 0 || this.askCustom.length > 0
                  ? this.p().brandSoft : this.p().bg)
                .onClick(() => {
                  this.submitAnswer();
                })
              Blank()
              // DSH 只有 dismiss 一种退出（Dismiss all questions）：取消就是取消，
              // 不给模型一个空答案冒充"跳过"。
              Text(this.askQuestions.length > 1 ? '取消全部' : '取消')
                .fontSize(12)
                .fontColor(this.p().textTertiary)
                .onClick(() => {
                  this.actions.cancelAsk();
                  this.askPicked = [];
                  this.askCustom = '';
                })
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .backgroundColor(this.p().card)
        .borderRadius(16)
      }

      Row({ space: 8 }) {
        Row({ space: 2 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(16)
              .fontColor([this.p().textSecondary])
          }
          .width(34)
          .height(34)
          .borderRadius(8)
          .onClick(() => {
            this.pickImages();
          })

          if (this.asrActive) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.mic_fill'))
                .fontSize(16)
                .fontColor([this.p().textSecondary])
              // Recognised words replace the prompt as they arrive, so the field is the
              // transcript rather than a sign covering it.
              Text(this.draft.length > 0 ? this.draft : '正在聆听…')
                .fontSize(14)
                .fontColor(this.draft.length > 0 ? this.p().textPrimary : this.p().textSecondary)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .height(36)
            .justifyContent(FlexAlign.Center)
          } else {
          TextArea({ text: this.draft, placeholder: '说点什么，/ 命令，@ 引用文件' })
            .layoutWeight(1)
            .constraintSize({ minHeight: 36, maxHeight: 132 })
            .backgroundColor(Color.Transparent)
            .padding({ left: 4, right: 4, top: 8, bottom: 8 })
            .fontSize(14)
            .fontColor(this.asrActive ? '#E5484D' : this.p().textPrimary)
            .placeholderColor(this.p().textTertiary)
            .onChange((v: string) => {
              this.draft = v;
              this.refreshSuggest(v);
            })
            .onFocus(() => {
              this.keyboardUp = true;
            })
            .onBlur(() => {
              this.keyboardUp = false;
            })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.holdTimer = setTimeout(() => {
                  this.holdTimer = -1;
                  this.startDictation();
                }, 600);
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                if (this.holdTimer >= 0) {
                  clearTimeout(this.holdTimer);
                  this.holdTimer = -1;
                } else {
                  this.stopDictation();
                }
              }
            })
          }
        }
        .layoutWeight(1)
        .backgroundColor(this.asrActive ? 'rgba(229,72,77,0.08)' : this.p().card)
        .borderRadius(12)
        .padding({ left: 2, right: 6, top: 3, bottom: 3 })

        // 一个按钮两副面孔：回合在跑且手上没字时是终止（红底白方块），其余时候是发送。
        // 只要输入框里有字，就一定是发送——那时候按下去的含义是「打断并插话」。
        Stack() {
          if (this.stopping()) {
            Rect({ width: 12, height: 12 })
              .radius(2)
              .fill('#FFFFFF')
          } else {
            SymbolGlyph($r('sys.symbol.paperplane_fill'))
              .fontSize(16)
              .fontColor([this.p().textPrimary])
          }
        }
        .width(38)
        .height(36)
        .backgroundColor(this.stopping() ? '#E5484D' : this.p().brandSoft)
        .borderRadius(10)
        .onClick(() => {
          if (this.stopping()) {
            this.actions.stop();
            return;
          }
          this.submit();
        })
      }
      .width('100%')
    }
    .width('100%')
  }

  build() {
    Column() {
      if (this.lines.length === 0) {
        // Nothing said yet: the title and the field are one centred block, the way a blank page
        // opens. Once a message lands the field drops to the bottom and stays there.
        Column({ space: 18 }) {
          Column({ space: 8 }) {
            Text(this.project.length > 0 ? this.project : '助手')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.p().textPrimary)
            Text('问点什么，或输入 / 看命令、@ 引用文件')
              .fontSize(13)
              .fontColor(this.p().textTertiary)
          }
          .alignItems(HorizontalAlign.Center)

          this.Composer()
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 12, right: 12 })
      } else {
        Row({ space: 10 }) {
          Text(this.project.length > 0 ? this.project : '未打开工程')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().textPrimary)
            .maxLines(1)
          Text(this.endpointLabel())
            .fontSize(11)
            .fontColor(this.p().textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Blank()
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 8 })


        // 待办在流内，不遮挡对话：收起时占一行，展开时限高内滚。
        if (this.todos.length > 0) {
          // 计划常驻在标题下，所以默认收起、收起时只有一行：它说明进度，不该占掉对话区。
          // 玻璃用系统 blurStyle + Palette 的半透明底与亮边，与 chat 标题栏同一套材质。
          if (!this.todoOpen) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(13)
                .fontColor([this.p().textTertiary])
              Text(this.todosDone() + '/' + this.todos.length)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.p().textPrimary)
              Text(this.todoSummary())
                .fontSize(12)
                .fontColor(this.p().textSecondary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('展开')
                .fontSize(11)
                .fontColor(this.p().textTertiary)
            }
            .width('100%')
            .height(30)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.p().bar)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .borderRadius(15)
            .border({ width: 1, color: glassEdge(this.dark) })
            .margin({ left: GAP, right: GAP, bottom: GAP })
            .onClick(() => {
              this.todoOpen = true;
            })
          } else {
            Column({ space: 6 }) {
              Row({ space: 6 }) {
                Text('待办')
                  .fontSize(12)
                  .fontColor(this.p().textSecondary)
                Text(this.todosDone() + '/' + this.todos.length)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.p().textPrimary)
                Blank()
                Text('收起')
                  .fontSize(11)
                  .fontColor(this.p().textTertiary)
              }
              .width('100%')
              .height(28)
              .onClick(() => {
                this.todoOpen = false;
              })

              Progress({
                value: this.todosDone(),
                total: Math.max(1, this.todos.length),
                type: ProgressType.Linear
              })
                .width('100%')
                .height(3)
                .color(this.p().brand)
                .backgroundColor(this.p().divider)

              Scroll() {
                Column({ space: 6 }) {
                ForEach(this.todoVisible(), (item: TodoViewItem) => {
                  Row({ space: 8 }) {
                    this.TodoMark(item.status)
                    Text(item.content)
                      .fontSize(13)
                      .fontColor(item.status === 'completed' ? this.p().textTertiary
                        : (item.status === 'in_progress' ? this.p().textPrimary : this.p().textSecondary))
                      .fontWeight(item.status === 'in_progress' ? FontWeight.Medium : FontWeight.Normal)
                      .decoration({
                        type: item.status === 'completed' ? TextDecorationType.LineThrough
                          : TextDecorationType.None,
                        color: this.p().textTertiary
                      })
                      .layoutWeight(1)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                }, (item: TodoViewItem, at: number) => String(at) + item.content)
                }
                .width('100%')
              }
              .constraintSize({ maxHeight: TODO_PANEL_MAX })
              .scrollBar(BarState.Auto)

              if (this.todos.length > TODO_SHOW) {
                Text('+ ' + String(this.todos.length - TODO_SHOW) + ' 条')
                  .fontSize(11)
                  .fontColor(this.p().textTertiary)
                  .width('100%')
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 6, bottom: 8 })
            .backgroundColor(this.p().bar)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .borderRadius(12)
            .border({ width: 1, color: glassEdge(this.dark) })
            .margin({ left: GAP, right: GAP, bottom: GAP })
          }
        }

        List({ space: 10, scroller: this.scroller }) {
          LazyForEach(this.source, (item: StreamItem, at: number) => {
            ListItem() {
              StreamItemView({
                kind: item.kind,
                text: item.text,
                title: item.title,
                activity: item.activity,
                closed: item.closed,
                closable: item.closable,
                itemKey: item.key,
                process: item.process,
                memberPreview: item.memberPreview,
                dark: this.dark,
                palette: this.p(),
                opened: $opened
              })
            }
          }, (item: StreamItem) => item.key + '#' + itemVersion(item))
        // 键里带版本：同键组件会被 LazyForEach 复用且不重赋 @Prop，正文长了键不变，
        // 画面就停在第一帧。带上版本后只有正在长的那一项被重建，其余项键不变。
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
        // Reading history must not be yanked away by the next token: the tail follows only while
        // the reader is already there.
        //
        // Judged on scroll stop rather than on scroll index: the index callback also fires when new
        // content extends the list, and at that instant the view is not at the end yet — so it
        // cleared the follow flag on every append, which is why new output stopped tracking the
        // bottom after the first line arrived.
        // 跟随状态只由手指的滚动决定。程序自己滚到底也会触发 onScrollStop，
        // 若在这里无脑按 isAtEnd() 写回，读者上翻一次就会被下一条 token 拽回底部。
        .onScrollStart(() => {
          this.follow.onScrollStart();
        })
        .onScrollStop(() => {
          this.follow.onScrollStop(this.scroller.isAtEnd());
        })


        // 状态行放进输入框容器：系统会保证输入框可见，它在容器内就跟着一起上去，
        // 不再依赖键盘高度（那个事件收起时不发 0）。
        Column() {
          this.Composer()
          // 键盘弹起时整条不渲染：它锚在输入框底部，加空白或内边距都推不动它。
          if (!this.keyboardUp) {
            this.StatusBar()
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 0 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.p().bg)
  }
}

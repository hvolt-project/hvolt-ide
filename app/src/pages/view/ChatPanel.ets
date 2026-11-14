// The chat surface: a transcript of blocks, with process folded according to the reader's mode.

import { palette, Palette } from '../model/Palette';
import { MarkdownView } from './MarkdownView';
import { ChatKind, ChatLine, foldable, lineDetail, lineKey, lineTitle, makeLine } from './ChatBlocks';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { applySuggestion, suggestFor, Suggestion } from '../model/Complete';
import { AskAnswer, AskOption, AskQuestion, progressLabel } from '../model/Ask';

export { ChatKind, ChatLine } from './ChatBlocks';

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
  @Link busy: boolean;
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
  /** True while the last row is on screen; new output then keeps the view pinned to the bottom. */
  private stickBottom: boolean = true;
  /** 手指正在滚：只有这种滚动才允许改变跟随状态。 */
  private userScrolling: boolean = false;
  /** 程序自己滚到底：不能让它把跟随状态改回去。 */
  private programmatic: boolean = false;
  /** Pending long-press on the field; -1 means the hold already became dictation. */
  private holdTimer: number = -1;
  /** Draft text before dictation, so interim results do not stack up. */
  /** The reader's own open/closed choices; they outlive a mode switch. */
  /** 每一行自己的开合，键是行下标；与 DSH 的 DisclosureRow 一样逐行管，不分档位。 */
  @State private opened: Map<string, boolean> = new Map();

  /** Follows the tail unless the reader has scrolled up; sending a message always returns to it. */
  onLinesChanged(): void {
    const last: ChatLine | null = this.lines.length > 0 ? this.lines[this.lines.length - 1] : null;
    if (last !== null && last.kind === 'user') {
      this.stickBottom = true;
    }
    // 手指正在拖动就不再吸底：否则新到的 token 会把读者刚翻上去的位置拽回底部。
    if (!this.stickBottom || this.userScrolling) {
      return;
    }
    // After the frame that added the row: scrolling before layout has grown the list reaches the
    // old bottom and stops short of the new last line.
    setTimeout(() => {
      // 定时器触发的这一刻读者可能已经开始上翻，按排程时的判断执行会把他拽回底部。
      if (!this.stickBottom || this.userScrolling) {
        return;
      }
      try {
        this.programmatic = true;
        this.scroller.scrollEdge(Edge.Bottom);
        setTimeout(() => {
          this.programmatic = false;
        }, 120);
      } catch (e) {
        this.programmatic = false;
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
  private submit(): void {
    const text = this.draft.trim();
    if (text.length === 0 || this.busy) {
      return;
    }
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

  @Builder
  Line(line: ChatLine) {
    if (line.kind === 'user') {
      Row() {
        Blank()
        Text(line.text)
          .fontSize(14)
          .lineHeight(20)
          .fontColor(this.p().textPrimary)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .backgroundColor(this.p().brandSoft)
          .borderRadius(14)
          .constraintSize({ maxWidth: '80%' })
          .textAlign(TextAlign.Start)
      }
      .width('100%')
    } else if (line.kind === 'assistant') {
      MarkdownView({ dark: this.dark, text: line.text })
        .width('100%')
    } else if (line.kind === 'error') {
      Text(line.text)
        .fontSize(12)
        .fontColor('#E5484D')
        .width('100%')
    } else {
      // 推理、工具、注入：一行标题，点开看细节。默认收起。
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(lineTitle(line))
            .fontSize(12)
            .fontColor(this.p().textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.isOpen(lineKey(line)) ? '收起' : '展开')
            .fontSize(12)
            .fontColor(this.p().textTertiary)
        }
        .width('100%')
        .onClick(() => {
          this.flip(lineKey(line));
        })

        if (this.isOpen(lineKey(line))) {
          Text(lineDetail(line))
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .padding({ left: 10 })
            .border({ width: { left: 2 }, color: this.p().divider })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  // The field carries attach and dictation on its left edge; sending is the only action that
  // sits outside it. Held-down dictation lives on the field itself, so there is no extra button.
  // Attach and dictation live on the field's left edge; sending is the only action outside it.
  // Dictation is a long press on the field itself rather than another button.
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

        Stack() {
          SymbolGlyph($r('sys.symbol.paperplane_fill'))
            .fontSize(16)
            .fontColor([this.p().textPrimary])
        }
        .width(38)
        .height(36)
        .backgroundColor(this.p().brandSoft)
        .borderRadius(10)
        .onClick(() => {
          this.submit();
        })
      }
      .width('100%')
    }
    .width('100%')
  }


  /** The question on screen, or an empty one while the list is being replaced. */
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

  /** chat 面自己的状态行：只属于这一面，与 IDE 底部那条无关。 */
  @Builder
  StatusBar() {
    Row({ space: 10 }) {
      Text(this.progressText())
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .maxLines(1)
      Blank()
      Text(this.costText())
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .maxLines(1)
      if (this.statPressure > 0) {
        Text(Math.round(this.statPressure) + '%')
          .fontSize(11)
          .fontColor(this.p().textTertiary)
          .maxLines(1)
      }
    }
    .width('100%')
    .height(26)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
  }

  private progressText(): string {
    const parts: string[] = ['轮 ' + this.statTurns, '步 ' + this.statSteps];
    if (this.statRate > 0) {
      parts.push(this.statRate >= 100 ? Math.round(this.statRate) + ' tok/s'
        : this.statRate.toFixed(1) + ' tok/s');
    }
    return parts.join(' ');
  }

  private costText(): string {
    const million = this.statTokens / 1000000;
    const amount = million >= 1 ? million.toFixed(1) + 'M'
      : this.statTokens >= 1000 ? (this.statTokens / 1000).toFixed(1) + 'K' : '' + this.statTokens;
    const parts: string[] = [amount + ' tok'];
    if (this.statCache >= 0) {
      parts.push('缓存 ' + Math.round(this.statCache) + '%');
    }
    return parts.join(' · ');
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
          if (this.busy) {
            Text('停止')
              .fontSize(13)
              .fontColor('#E5484D')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .onClick(() => {
                this.actions.stop();
              })
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 8 })

        List({ space: 10, scroller: this.scroller }) {
          ForEach(this.lines, (line: ChatLine, at: number) => {
            ListItem() {
              this.Line(line)
            }
          }, (line: ChatLine, at: number) => String(at) + ':' + lineKey(line))
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
          // 程序自己滚到底也会走到这里，那不是读者的意图，不能因此关掉跟随。
          if (this.programmatic) {
            return;
          }
          // 起手即停止吸底：拖动过程中新内容还在到达，等到抬手才判断已经把人拽住了。
          this.userScrolling = true;
          this.stickBottom = false;
        })
        .onScrollStop(() => {
          if (this.programmatic) {
            this.userScrolling = false;
            return;
          }
          if (this.userScrolling) {
            this.stickBottom = this.scroller.isAtEnd();
          }
          this.userScrolling = false;
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

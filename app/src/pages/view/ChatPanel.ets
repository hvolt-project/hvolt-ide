// The chat surface: a transcript of blocks, with process folded according to the reader's mode.

import { palette, Palette } from '../model/Palette';
import { MarkdownView } from './MarkdownView';
import { buildBlocks, ChatBlock, ChatKind, ChatLine, FoldMode } from './ChatBlocks';
import { AsrSession } from '../harness/asr/Asr';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { applySuggestion, suggestFor, Suggestion } from '../model/Complete';

export { ChatKind, ChatLine, FoldMode } from './ChatBlocks';

export interface ChatActions {
  send: (text: string, images: string[]) => void;
  stop: () => void;
  reset: () => void;
  close: () => void;
}

@Component
export struct ChatPanel {
  @Prop dark: boolean = true;
  @Prop mode: FoldMode = 'normal';
  /** Project name is the headline; the endpoint identity sits under it. */
  @Prop project: string = '';
  @Prop provider: string = '';
  @Prop model: string = '';
  /** Project files, for @ completion. */
  @Prop files: string[] = [];
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
  /** Completion slate shown above the input while the draft starts with / or @. */
  @State private suggest: string[] = [];
  @State private suggestKind: string = '';
  @State private asrActive: boolean = false;
  /** Attachments for the next message, as data URLs. */
  @State private attachments: string[] = [];
  private asr: AsrSession = new AsrSession();
  private scroller: Scroller = new Scroller();
  /** True while the last row is on screen; new output then keeps the view pinned to the bottom. */
  private stickBottom: boolean = true;
  /** Pending long-press on the field; -1 means the hold already became dictation. */
  private holdTimer: number = -1;
  /** Draft text before dictation, so interim results do not stack up. */
  /** The reader's own open/closed choices; they outlive a mode switch. */
  @State private toggled: Map<string, boolean> = new Map();

  /** Follows the tail only when it was already at the tail; reading further up is left alone. */
  onLinesChanged(): void {
    if (!this.stickBottom) {
      return;
    }
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // The list is not mounted yet (empty conversation); nothing to follow.
      }
    }, 16);
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
    this.asrActive = true;
    this.asr.start((text: string, final: boolean) => {
      this.draft = text;
    }, (message: string) => {
      this.asrActive = false;
      this.showToast(message);
    }).catch(() => {
      this.asrActive = false;
    });
  }

  private stopDictation(): void {
    if (!this.asrActive) {
      return;
    }
    this.asrActive = false;
    this.asr.stop();
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
    if (item === '/reset' || item === '/clear') {
      return '清空这段对话';
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
    if (text === '/reset' || text === '/clear') {
      this.confirmClear();
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

  private flip(key: string, current: boolean): void {
    const next: Map<string, boolean> = new Map();
    this.toggled.forEach((value: boolean, at: string) => {
      next.set(at, value);
    });
    next.set(key, !current);
    this.toggled = next;
  }

  @Builder
  ProcessItem(item: ChatLine) {
    if (item.kind === 'thought') {
      Text(item.text.length === 0 ? '…' : item.text)
        .fontSize(12)
        .lineHeight(18)
        .fontColor(this.p().textTertiary)
        .width('100%')
        .padding({ left: 10 })
        .border({ width: { left: 2 }, color: this.p().divider })
    } else {
      Row({ space: 6 }) {
        Text(item.name.length > 0 ? item.name : '工具')
          .fontSize(12)
          .fontColor(this.p().textSecondary)
        Text(item.text)
          .fontSize(11)
          .fontColor(this.p().textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
    }
  }

  @Builder
  Block(block: ChatBlock) {
    if (block.kind === 'user') {
      Row() {
        Blank()
        Text(block.text)
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
    } else if (block.kind === 'stats') {
      Text(block.text)
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .width('100%')
    } else if (block.kind === 'group') {
      Column({ space: 6 }) {
        Row() {
          Text(block.open ? '过程' : block.summary)
            .fontSize(12)
            .fontColor(this.p().textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(block.open ? '收起' : '展开')
            .fontSize(12)
            .fontColor(this.p().textTertiary)
        }
        .width('100%')
        .onClick(() => {
          this.flip(block.key, block.open);
        })

        if (block.open) {
          ForEach(block.items, (item: ChatLine, index: number) => {
            this.ProcessItem(item)
          }, (item: ChatLine, index: number) => index + ':' + item.kind + ':' + item.text.length)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else {
      MarkdownView({ dark: this.dark, text: block.text })
        .width('100%')
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
          ForEach(buildBlocks(this.lines, this.mode, this.toggled), (block: ChatBlock) => {
            ListItem() {
              this.Block(block)
            }
          }, (block: ChatBlock) => block.key + ':' + block.open + ':' + block.text.length + ':' + block.items.length)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
        // Reading history must not be yanked away by the next token: the tail follows only while
        // the reader is already there.
        .onScrollIndex(() => {
          this.stickBottom = this.scroller.isAtEnd();
        })

        Column() {
          this.Composer()
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.p().bg)
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, fingers: 2 })
        .onActionEnd((event: GestureEvent) => {
          if (event.offsetX > 80) {
            this.actions.close();
          }
        })
    )
  }
}

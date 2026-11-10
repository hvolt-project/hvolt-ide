// The chat surface: a transcript of blocks, with process folded according to the reader's mode.

import { palette, Palette } from '../model/Palette';
import { MarkdownView } from './MarkdownView';
import { buildBlocks, ChatBlock, ChatKind, ChatLine, FoldMode } from './ChatBlocks';

export { ChatKind, ChatLine, FoldMode } from './ChatBlocks';

export interface ChatActions {
  send: (text: string) => void;
  stop: () => void;
  reset: () => void;
  close: () => void;
}

@Component
export struct ChatPanel {
  @Prop dark: boolean = true;
  @Prop mode: FoldMode = 'normal';
  @Link lines: ChatLine[];
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
  /** The reader's own open/closed choices; they outlive a mode switch. */
  @State private toggled: Map<string, boolean> = new Map();

  private p(): Palette {
    return palette(this.dark);
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

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('对话')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().textPrimary)
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
        Text('清空')
          .fontSize(13)
          .fontColor(this.p().textSecondary)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.actions.reset();
          })
        Text('返回')
          .fontSize(13)
          .fontColor(this.p().textSecondary)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.actions.close();
          })
      }
      .width('100%')
      .height(48)
      .padding({ left: 14, right: 8 })

      List({ space: 10 }) {
        ForEach(buildBlocks(this.lines, this.mode, this.toggled), (block: ChatBlock) => {
          ListItem() {
            this.Block(block)
          }
        }, (block: ChatBlock) => block.key + ':' + block.text.length + ':' + block.items.length)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })

      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '说点什么，或让助手改代码' })
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .fontColor(this.p().textPrimary)
          .placeholderColor(this.p().textTertiary)
          .backgroundColor(this.p().card)
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .onChange((v: string) => {
            this.draft = v;
          })
        Text('发送')
          .fontSize(14)
          .fontColor(this.p().textPrimary)
          .height(42)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.p().brandSoft)
          .borderRadius(12)
          .onClick(() => {
            const text = this.draft.trim();
            if (text.length === 0 || this.busy) {
              return;
            }
            this.draft = '';
            this.actions.send(text);
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
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

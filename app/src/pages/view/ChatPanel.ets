// Full-screen chat surface. It renders what the loop reports and forwards the user's input; it
// owns no conversation state beyond what is on screen, so closing and reopening it cannot fork
// the history.

import { palette, Palette } from '../model/Palette';
import { MarkdownView } from './MarkdownView';

export type ChatKind = 'user' | 'assistant' | 'tool' | 'error' | 'thought';

export interface ChatLine {
  kind: ChatKind;
  text: string;
  /** Reasoning is folded by default; a tap opens it. Ignored by other kinds. */
  open: boolean;
}

export interface ChatActions {
  send: (text: string) => void;
  stop: () => void;
  reset: () => void;
  close: () => void;
}

@Component
export struct ChatPanel {
  @Prop dark: boolean = true;
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

  private p(): Palette {
    return palette(this.dark);
  }

  private toggle(line: ChatLine): void {
    const next: ChatLine[] = [];
    for (const entry of this.lines) {
      next.push(entry === line ? { kind: entry.kind, text: entry.text, open: !entry.open } : entry);
    }
    this.lines = next;
  }

  private tone(kind: ChatKind): string {
    if (kind === 'user') {
      return this.p().brand;
    }
    if (kind === 'error') {
      return '#E5484D';
    }
    if (kind === 'tool') {
      return this.p().textTertiary;
    }
    return this.p().textPrimary;
  }

  // Sent text is a bubble on the right; replies are a document, not a bubble. A tool call is a
  // single quiet line: it is a fact about the turn, not something addressed to the reader.
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
    } else if (line.kind === 'thought') {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(line.open ? '思考' : '思考 · ' + line.text.length + ' 字')
            .fontSize(12)
            .fontColor(this.p().textTertiary)
          Blank()
          Text(line.open ? '收起' : '展开')
            .fontSize(12)
            .fontColor(this.p().textTertiary)
        }
        .width('100%')
        .onClick(() => {
          this.toggle(line);
        })

        if (line.open) {
          Text(line.text.length === 0 ? '…' : line.text)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .padding({ left: 8 })
            .border({ width: { left: 2 }, color: this.p().divider })
        }
      }
      .width('100%')
    } else if (line.kind === 'tool') {
      Text(line.text)
        .fontSize(12)
        .fontColor(this.p().textTertiary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    } else if (line.kind === 'error') {
      Text(line.text)
        .fontSize(13)
        .lineHeight(19)
        .fontColor('#E5484D')
        .width('100%')
    } else {
      MarkdownView({ dark: this.dark, text: line.text })
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

      List({ space: 8 }) {
        ForEach(this.lines, (line: ChatLine, index: number) => {
          ListItem() {
            this.Line(line)
          }
        }, (line: ChatLine, index: number) => index + ':' + line.kind)
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
    // Swipe right to turn back to the editor — the same page-turn, in reverse.
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

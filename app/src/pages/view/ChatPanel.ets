// Full-screen chat surface. It renders what the loop reports and forwards the user's input; it
// owns no conversation state beyond what is on screen, so closing and reopening it cannot fork
// the history.

import { palette, Palette } from '../model/Palette';

export type ChatKind = 'user' | 'assistant' | 'tool' | 'error';

export interface ChatLine {
  kind: ChatKind;
  text: string;
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

  @Builder
  Bubble(line: ChatLine) {
    Column({ space: 4 }) {
      Text(line.kind === 'tool' ? '工具' : (line.kind === 'user' ? '你' : '助手'))
        .fontSize(10)
        .fontColor(this.p().textTertiary)
        .width('100%')
      Text(line.text.length === 0 ? '…' : line.text)
        .fontSize(13)
        .lineHeight(19)
        .fontColor(this.tone(line.kind))
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor(line.kind === 'tool' ? this.p().bg : this.p().card)
    .borderRadius(12)
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
            this.Bubble(line)
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

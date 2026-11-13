import uiMaterial from '@ohos.arkui.uiMaterial';
import { glassEdge, linkColor, palette, Palette, RADIUS, toneColor } from '../model/Palette';

const DOCK_MATERIAL: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  applyShadow: true,
  colorInvert: false
});
import { DURATION, spring } from '../model/Motion';
import { lastSegment } from '../model/Util';

// One surface for the whole bottom edge: tabs, the log and the status row. It also
// owns the bottom safe area — the surface itself runs to the screen edge and pads
// its content up by the inset, so the gesture bar sits on the dock, not on wallpaper.
@Component
export struct BottomDock {
  @Prop dark: boolean = true;
  @Prop compact: boolean = true;
  @Prop bottomInset: number = 0;
  @Prop statusText: string = '';
  @Prop statusTone: number = 0;
  // Session figures for the row above the strip. Passed as loose numbers because ArkUI copies
  // plain props cheaply; a stats object would be deep-copied on every repaint.
  @Prop log: string = '';
  @Prop current: string = '';
  @Prop hlog: string = '';
  onTab: (idx: number) => void = () => {
  };
  @Link panelOpen: boolean;
  @Link panelTab: number;
  @Prop link: number = 0;
  @Prop linkText: string = '';
  @Prop device: string = '';
  onDeviceTap: () => void = () => {
  };
  onFilter: (keyword: string, tag: string, level: string) => void = () => {
  };
  @State private draftKeyword: string = '';
  @State private draftTag: string = '';
  @State private draftLevel: string = '';
  @StorageProp('ide.pos') pos: string = '';
  @StorageProp('ide.chromeHidden') chromeHidden: boolean = false;

  private p(): Palette {
    return palette(this.dark);
  }

  @Builder
  Icon(sym: Resource, tap: () => void) {
    Stack() {
      SymbolGlyph(sym).fontSize(22).fontColor([this.p().textPrimary])
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .onClick(tap)
  }

  // Both chevrons are in the system set; the pair is deliberately opposite so the state
  // is readable without colour.
  @Builder
  Toggle() {
    Stack() {
      SymbolGlyph(this.panelOpen ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
        .fontSize(18)
        .fontColor([this.p().textSecondary])
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .onClick(() => {
      animateTo({ duration: DURATION, curve: spring() }, () => {
        this.panelOpen = !this.panelOpen;
      });
    })
  }

  @Builder
  Tab(label: string, idx: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.panelTab === idx ? this.p().brand : this.p().textSecondary)
      .fontWeight(this.panelTab === idx ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(10)
      .backgroundColor(this.panelTab === idx ? this.p().brandSoft : Color.Transparent)
      .onClick(() => {
        animateTo({ duration: DURATION, curve: spring() }, () => {
          this.panelTab = idx;
          this.panelOpen = true;
        });
        this.onTab(idx);
      })
  }

  // Filters are applied on demand: restarting the follower on every keystroke would drop
  // and reopen the device stream while the keyboard is still open.
  @Builder
  FilterRow() {
    Row({ space: 6 }) {
      TextInput({ text: this.draftKeyword, placeholder: '关键字' })
        .height(30)
        .layoutWeight(2)
        .fontSize(12)
        .fontColor(this.p().textPrimary)
        .placeholderColor(this.p().textTertiary)
        .backgroundColor(this.p().pane)
        .borderRadius(8)
        .padding({ left: 8, right: 8 })
        .onChange((v: string) => {
          this.draftKeyword = v;
        })
      TextInput({ text: this.draftTag, placeholder: 'tag' })
        .height(30)
        .layoutWeight(2)
        .fontSize(12)
        .fontColor(this.p().textPrimary)
        .placeholderColor(this.p().textTertiary)
        .backgroundColor(this.p().pane)
        .borderRadius(8)
        .padding({ left: 8, right: 8 })
        .onChange((v: string) => {
          this.draftTag = v;
        })
      Text(this.draftLevel.length === 0 ? '全部' : this.draftLevel)
        .height(30)
        .fontSize(12)
        .fontColor(this.p().textSecondary)
        .padding({ left: 10, right: 10 })
        .borderRadius(8)
        .backgroundColor(this.p().pane)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          // One control cycles through the levels rather than a picker: the panel is a
          // strip, not a form.
          const order: string[] = ['', 'D', 'I', 'W', 'E'];
          const at = order.indexOf(this.draftLevel);
          this.draftLevel = order[(at + 1) % order.length];
        })
      Text('应用')
        .height(30)
        .fontSize(12)
        .fontColor(this.p().brand)
        .padding({ left: 10, right: 10 })
        .borderRadius(8)
        .backgroundColor(this.p().brandSoft)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onFilter(this.draftKeyword.trim(), this.draftTag.trim(), this.draftLevel);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 2, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  Body() {
    Scroll() {
      Text(this.text())
        .fontSize(11)
        .fontColor(this.p().textSecondary)
        .lineHeight(18)
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
    }
    .width('100%')
    .height(this.compact ? 150 : 190)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  private text(): string {
    if (this.panelTab === 1) {
      return this.hlog.length === 0 ? '点 hilog 页签读取设备日志' : this.hlog;
    }
    return this.log.length === 0 ? '暂无输出' : this.log;
  }

  build() {
    Column() {
      // The glass surface is the dock proper. The status row below it is chrome, not
      // content, so it sits on the real background colour instead of a second tint.
      Column() {
          Row({ space: 4 }) {
          this.Tab('构建', 0)
          this.Tab('hilog', 1)
          Blank()
          this.Toggle()
        }
        .width('100%')
        .height(40)
        .padding({ left: 10, right: 4 })
        .alignItems(VerticalAlign.Center)

          if (this.panelOpen && this.panelTab === 1) {
            this.FilterRow()
          }
          if (this.panelOpen) {
            this.Body()
          }
        }
        .width('100%')
        .height(this.chromeHidden ? 0 : (this.panelOpen ? 190 : 40))
        .opacity(this.chromeHidden ? 0 : 1)
        .backgroundColor(Color.Transparent)
        .systemMaterial(DOCK_MATERIAL)
        .borderRadius({ topLeft: RADIUS, topRight: RADIUS, bottomLeft: 0, bottomRight: 0 })
        // Edge stroke only on the sides that are free: the outline is what makes the
        // rounded corners legible against the editor card above.
        .border({
          width: { top: 0.5, left: 0.5, right: 0.5, bottom: 0 },
          color: { top: glassEdge(this.dark), left: glassEdge(this.dark), right: glassEdge(this.dark) }
        })
        .clip(true)
        .animation({ duration: DURATION, curve: Curve.FastOutSlowIn })

      Divider()
        .color(this.p().divider)
        .strokeWidth(0.5)
        .opacity(this.chromeHidden ? 0 : 1)

      Row({ space: 10 }) {
        // Left: the dot is the connection state and the address is what it is about, so
        // the two form one tappable block that leads to the place it can be changed.
        Row({ space: 6 }) {
          Circle({ width: 6, height: 6 }).fill(linkColor(this.p(), this.link))
          Text(this.device)
            .fontSize(11)
            .fontColor(this.p().textTertiary)
            .maxLines(1)
            .flexShrink(0)
          if (this.link !== 2 && this.linkText.length > 0) {
            Text(this.linkText)
              .fontSize(11)
              .fontColor(linkColor(this.p(), this.link))
              .maxLines(1)
          }
        }
        .onClick(() => {
          this.onDeviceTap();
        })

        Text(this.statusText.length === 0 ? '就绪' : this.statusText)
          .fontSize(11)
          .fontColor(toneColor(this.p(), this.statusTone))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => {
            animateTo({ duration: DURATION, curve: spring() }, () => {
              this.panelOpen = true;
              this.panelTab = 0;
            });
          })

        Text('Ln ' + this.position())
          .fontSize(11)
          .fontColor(this.p().textTertiary)
          .maxLines(1)
          .flexShrink(0)
      }
      .width('100%')
      // Only the gesture bar's own height is left below the strip; the safe-area value is
      // wider than the pill and read as dead space.
      .height(30)
      .padding({ left: 14, right: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.p().bg)

    }
    .width('100%')
    // The glass plate above animates its height on every tab switch; while the material
    // re-renders there is nothing behind it and the window's white shows through. The
    // container carries the same colour so that gap is never white.
    .backgroundColor(this.p().bg)
  }

  /** 状态行的位置段：本机转发地址只留端口，整条状态行才放得下。 */
  private position(): string {
    return this.pos.length === 0 ? '—' : this.pos;
  }
}

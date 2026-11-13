import { glassEdge, palette, Palette } from '../model/Palette';

// The wide shapes keep the view switcher out of the pane itself: a 48vp column owns it,
// with the settings gear pinned to the bottom.
const BAR_W: number = 48;
const CELL: number = 32;

@Component
export struct ActivityBar {
  @Prop dark: boolean = true;
  @StorageProp('ide.view') view: number = 0;
  onSettings: () => void = () => {
  };
  onChat: () => void = () => {
  };

  private p(): Palette {
    return palette(this.dark);
  }

  @Builder
  Item(sym: Resource, idx: number) {
    Stack() {
      SymbolGlyph(sym)
        .fontSize(18)
        .fontColor([this.view === idx ? this.p().brand : this.p().textTertiary])
    }
    .width(CELL)
    .height(CELL)
    .borderRadius(9)
    .backgroundColor(this.view === idx ? this.p().brandSoft : Color.Transparent)
    .onClick(() => {
      AppStorage.setOrCreate('ide.view', idx);
    })
  }

  build() {
    Column({ space: 6 }) {
      this.Item($r('sys.symbol.folder'), 0)
      this.Item($r('sys.symbol.list_bullet'), 1)
      this.Item($r('sys.symbol.link'), 2)
      Blank()
      Stack() {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(18)
          .fontColor([this.p().textTertiary])
      }
      .width(CELL)
      .height(CELL)
      .borderRadius(9)
      .onClick(this.onSettings)
    }
    .width(BAR_W)
    .height('100%')
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(this.p().surface)
    .border({ width: 0.5, color: glassEdge(this.dark) })
    .alignItems(HorizontalAlign.Center)
  }
}

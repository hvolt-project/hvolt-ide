import uiMaterial from '@ohos.arkui.uiMaterial';
import { glassEdge, palette, Palette } from '../model/Palette';
import { lastSegment } from '../model/Util';

// Measurements come from docs/ide-action-pill.svg, not from what fits: the pill is
// 96x32 with three 28vp cells and 16vp glyphs, and the tab strip runs underneath it so
// the overflow is occlusion instead of a control.
const BAR_H: number = 40;
const TAB_H: number = 32;
const TAB_TEXT_MAX: number = 96;
const TAB_R: number = 10;
const PILL_W: number = 96;
const PILL_H: number = 32;
const CELL: number = 28;
const CELL_GAP: number = 2;
const ICON: number = 16;
const HIT: number = 40;
const EDGE: number = 14;
const PILL_INSET: number = 4;
// Same gap on both sides of the strip: the menu cell and the pill sit one step away from it.
const STRIP_GAP: number = 4;
const DOT: number = 5;
// The phone bar shows two of the three actions; the third is one swipe away instead of
// widening the pill over the editor.
const PILL_SLOTS: number = 2;
const PILL_PAD: number = 4;
const PILL_VISIBLE: number = CELL * PILL_SLOTS + CELL_GAP * (PILL_SLOTS - 1) + PILL_PAD * 2;
const HIT_PAD: number = (HIT - CELL) / 2;

// System material, not a blur filter: the platform draws the glass layer, so it can shift
// tints with the content underneath instead of just smearing it.
const BAR_MATERIAL: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  applyShadow: true,
  colorInvert: false
});
const PILL_MATERIAL: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  applyShadow: true,
  colorInvert: false
});

// Title bar: the tab strip owns the width, the run controls float over its right end.
@Component
export struct TopBar {
  @Prop dark: boolean = true;
  @Prop showToggle: boolean = false;
  @StorageProp('ide.tabs') files: string[] = [];
  @StorageProp('ide.current') @Watch('onCurrentChanged') current: string = '';
  @StorageProp('ide.dirty') dirty: string[] = [];
  onToggle: () => void = () => {
  };
  onSelect: (rel: string) => void = () => {
  };
  onClose: (rel: string) => void = () => {
  };
  onBuild: () => void = () => {
  };
  onInstall: () => void = () => {
  };
  onStart: () => void = () => {
  };

  private p(): Palette {
    return palette(this.dark);
  }

  private scroller: Scroller = new Scroller();

  // Selecting a file scrolls its tab into view: a strip left scrolled from an earlier
  // gesture would otherwise keep the active tab off screen.
  private onCurrentChanged(): void {
    const at = this.files.indexOf(this.current);
    if (at >= 0) {
      this.scroller.scrollToIndex(at);
    }
  }

  private isDirty(rel: string): boolean {
    return this.dirty.indexOf(rel) >= 0;
  }

  @Builder
  Cell(sym: Resource, tap: () => void) {
    Stack() {
      // Multicolor symbols keep their own accent layer, which reads as a second stroke
      // next to the shape; one tone keeps the three actions visually equal.
      SymbolGlyph(sym)
        .fontSize(ICON)
        .fontColor([this.p().textSecondary])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .width(CELL)
    .height(CELL)
    .borderRadius(CELL / 2)
    .backgroundColor(this.p().bg)
    // The cell is 28vp but the finger is not: the hit area reaches 40vp outward without
    // moving anything.
    .responseRegion({ x: -HIT_PAD, y: -HIT_PAD, width: HIT, height: HIT })
    .onClick(tap)
  }

  @Builder
  Tab(rel: string) {
    Row({ space: 6 }) {
      if (this.isDirty(rel)) {
        Circle({ width: DOT, height: DOT })
          .fill(this.p().textSecondary)
      }
      Text(lastSegment(rel))
        .constraintSize({ maxWidth: TAB_TEXT_MAX })
        .fontSize(13)
        .fontColor(rel === this.current ? this.p().textPrimary : this.p().textSecondary)
        .fontWeight(rel === this.current ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (rel === this.current) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(11)
          .fontColor([this.p().textTertiary])
          .responseRegion({ x: -8, y: -10, width: 30, height: TAB_H })
          .onClick(() => {
            this.onClose(rel);
          })
      }
    }
    .height(TAB_H)
    .padding({ left: 12, right: 10 })
    .borderRadius(TAB_R)
    // A tab is edged all round, so it reads as one plate regardless of its neighbours.
    .border({ width: 0.5, color: this.p().divider })
    .backgroundColor(rel === this.current ? this.p().brandSoft : Color.Transparent)
    .onClick(() => {
      this.onSelect(rel);
    })
  }

  build() {
    Row({ space: STRIP_GAP }) {
      if (this.showToggle) {
        // Same cell as the run controls, so both ends of the bar read as the same control.
        this.Cell($r('sys.symbol.list_bullet'), this.onToggle)
      }

      Row() {
        List({ space: 2, scroller: this.scroller }) {
          ForEach(this.files, (rel: string) => {
            ListItem() {
              this.Tab(rel)
            }
            .height(TAB_H)
          }, (rel: string) => rel)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .height(TAB_H)

        List({ space: CELL_GAP }) {
          ListItem() {
            this.Cell($r('sys.symbol.hammer_fill'), this.onBuild)
          }
          ListItem() {
            this.Cell($r('sys.symbol.square_and_arrow_down'), this.onInstall)
          }
          ListItem() {
            this.Cell($r('sys.symbol.play_fill'), this.onStart)
          }
        }
        .listDirection(Axis.Horizontal)
        // Cross-axis centring keeps the glyphs off the top edge when the pill is taller
        // than the cells.
        .alignListItem(ListItemAlign.Center)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .height(PILL_H)
        .width(PILL_VISIBLE)
        .padding({ left: PILL_PAD, right: PILL_PAD })
        .borderRadius(PILL_H / 2)
        .backgroundColor(this.p().surface)
        .systemMaterial(PILL_MATERIAL)
        .border({ width: 0.5, color: glassEdge(this.dark) })
        .shadow({ radius: 16, color: '#33000000', offsetY: 2 })
        .margin({ left: STRIP_GAP, right: PILL_INSET })
      }
      .layoutWeight(1)
      .height(BAR_H)
    }
    .width('100%')
    .height(BAR_H)
    .padding({ left: PILL_INSET })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.p().surface)
    // No top edge: the bar has to read as one surface with the system status strip above it.
    .border({ width: { bottom: 0.5 }, color: { bottom: glassEdge(this.dark) } })
    // The bar runs edge to edge under the system status area, so only its lower corners
    // round off; rounding the top leaves two crescents of background against the screen.
    .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: TAB_R + 4, bottomRight: TAB_R + 4 })
    .clip(true)
  }
}

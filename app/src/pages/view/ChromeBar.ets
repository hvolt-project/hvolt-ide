import { DURATION } from '../model/Motion';
import { palette, Palette } from '../model/Palette';
import { TopBar } from './TopBar';

// 标题带：Tab 条占满宽度，运行控制浮在它的右端；下面一行是「工程 › 目录 › 文件」的路径。
// 面包屑直接从 AppStorage 推导，页面不再为它维护一份方法。
@Component
export struct ChromeBar {
  @Prop dark: boolean = true;
  @Prop showToggle: boolean = false;
  @StorageProp('ide.chromeHidden') chromeHidden: boolean = false;
  @StorageProp('ide.project') project: string = '';
  @StorageProp('ide.current') current: string = '';

  onToggle: () => void = () => {};
  onSelectTab: (rel: string) => void = () => {};
  onCloseTab: (rel: string) => void = () => {};
  onBuild: () => void = () => {};
  onInstall: () => void = () => {};
  onStart: () => void = () => {};

  private p(): Palette {
    return palette(this.dark);
  }

  private crumbs(): string[] {
    const out: string[] = [];
    if (this.project.length > 0) {
      out.push(this.project);
    }
    if (this.current.length === 0) {
      return out;
    }
    const parts = this.current.split('/');
    for (let i = 0; i < parts.length; i++) {
      out.push(parts[i]);
    }
    return out;
  }

  build() {
    Row() {
      Column() {
        TopBar({
          dark: this.dark,
          showToggle: this.showToggle,
          onToggle: this.onToggle,
          onSelect: this.onSelectTab,
          onClose: this.onCloseTab,
          onBuild: this.onBuild,
          onInstall: this.onInstall,
          onStart: this.onStart
        })

        Row({ space: 6 }) {
          ForEach(this.crumbs(), (seg: string, i: number) => {
            if (i > 0) {
              Text('›')
                .fontSize(11)
                .fontColor(this.p().textTertiary)
            }
            Text(seg)
              .fontSize(11)
              .fontColor(i === 0 ? this.p().textSecondary : this.p().textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (seg: string, i: number) => i.toString() + seg)
        }
        .width('100%')
        .height(22)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.p().bg)
      }
      .width('100%')
    }
    .width('100%')
    .height(this.chromeHidden ? 0 : 62)
    .opacity(this.chromeHidden ? 0 : 1)
    .clip(true)
    .animation({ duration: DURATION, curve: Curve.FastOutSlowIn })
  }
}

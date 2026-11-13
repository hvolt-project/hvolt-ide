import uiMaterial from '@ohos.arkui.uiMaterial';
import { glassEdge, palette, Palette, RADIUS } from '../model/Palette';

const PANE_MATERIAL: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.REGULAR,
  applyShadow: true,
  colorInvert: false
});
import { DURATION, spring } from '../model/Motion';
import { lastSegment } from '../model/Util';

// One row of the explorer: a directory or a file, already flattened with its depth so the
// list builder stays a ForEach instead of a recursion.
class Node {
  path: string = '';
  name: string = '';
  depth: number = 0;
  dir: boolean = false;

  constructor(path: string, name: string, depth: number, dir: boolean) {
    this.path = path;
    this.name = name;
    this.depth = depth;
    this.dir = dir;
  }
}

function walkTree(prefix: string, depth: number, files: string[], expanded: string[],
  out: Node[]): void {
  const dirs: string[] = [];
  const leaves: string[] = [];
  for (let i = 0; i < files.length; i++) {
    const f = files[i];
    if (prefix.length > 0 && f.substring(0, prefix.length + 1) !== prefix + '/') {
      continue;
    }
    const rest = prefix.length === 0 ? f : f.substring(prefix.length + 1);
    const cut = rest.indexOf('/');
    if (cut >= 0) {
      const d = rest.substring(0, cut);
      if (dirs.indexOf(d) < 0) {
        dirs.push(d);
      }
    } else if (rest.length > 0) {
      leaves.push(rest);
    }
  }
  // Directories first: the tree reads as structure, then as files.
  for (let i = 0; i < dirs.length; i++) {
    const path = prefix.length === 0 ? dirs[i] : prefix + '/' + dirs[i];
    out.push(new Node(path, dirs[i], depth, true));
    if (expanded.indexOf(path) >= 0) {
      walkTree(path, depth + 1, files, expanded, out);
    }
  }
  for (let i = 0; i < leaves.length; i++) {
    const path = prefix.length === 0 ? leaves[i] : prefix + '/' + leaves[i];
    out.push(new Node(path, leaves[i], depth, false));
  }
}

function flattenTree(files: string[], expanded: string[]): Node[] {
  const out: Node[] = [];
  walkTree('', 0, files, expanded, out);
  return out;
}

// The project menu: a view switcher on top (the same three entries the wide shapes park in
// an activity bar) and one of three views below it. The ⋮ carries the actions that do not
// deserve a row of their own.
@Component
export struct LeftPane {
  @Prop dark: boolean = true;
  // Width comes from the breakpoint that hosts the pane: 232 as a phone drawer, 240 in
  // the medium flow, 260 once an activity bar takes over the switching.
  @Prop paneWidth: number = 232;
  @StorageProp('ide.projects') projects: string[] = [];
  @StorageProp('ide.project') project: string = '';
  @StorageProp('ide.files') files: string[] = [];
  @StorageProp('ide.current') current: string = '';
  @StorageProp('ide.device') device: string = '';
  @StorageProp('ide.link') linkState: string = '';
  @StorageProp('ide.agc') agcState: string = '';
  @StorageProp('ide.outline') outline: string[] = [];
  @StorageProp('ide.outlineNote') outlineNote: string = '';
  onOpen: (rel: string) => void = () => {
  };
  onCreate: (name: string) => void = () => {
  };
  onSwitch: (name: string) => void = () => {
  };
  onOpenProject: () => void = () => {
  };
  onCloseProject: () => void = () => {
  };
  onSettings: () => void = () => {
  };
  // Re-reads the open project from disk: the tree is a snapshot taken when the project
  // was opened, so anything the toolchain wrote since then is invisible until this runs.
  onRefresh: () => void = () => {
  };
  onDeleteFile: (rel: string) => void = () => {
  };
  onCreateFile: (dirRel: string, name: string) => void = () => {
  };
  onImportFiles: (dirRel: string) => void = () => {
  };

  @State private view: number = 0;
  @State private expanded: string[] = ['src', 'src/pages'];
  onChat: () => void = () => {
  };
  @State private naming: boolean = false;
  @State private newName: string = '';
  @State private fileNaming: boolean = false;
  @State private fileName: string = '';
  @State private fileDir: string = '';

  private p(): Palette {
    return palette(this.dark);
  }

  // Closing is only offered when something is open; on the empty state the entry would
  // point at nothing.
  private menuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '打开工程',
        action: () => {
          this.onOpenProject();
        }
      },
      {
        value: '新建工程',
        action: () => {
          this.newName = '';
          this.naming = true;
        }
      }
    ];
    if (this.project.length > 0) {
      items.push({
        value: '关闭当前项目',
        action: () => {
          this.onCloseProject();
        }
      });
    }
    return items;
  }

  private toggle(path: string): void {
    const at = this.expanded.indexOf(path);
    if (at >= 0) {
      this.expanded.splice(at, 1);
    } else {
      this.expanded.push(path);
    }
  }

  @Builder
  ViewIcon(sym: Resource, idx: number) {
    Stack() {
      SymbolGlyph(sym)
        .fontSize(16)
        .fontColor([this.view === idx ? this.p().brand : this.p().textTertiary])
    }
    .width(28)
    .height(28)
    .borderRadius(8)
    .backgroundColor(this.view === idx ? this.p().brandSoft : Color.Transparent)
    .onClick(() => {
      this.view = idx;
    })
  }

  @Builder
  TreeRow(node: Node) {
    Row({ space: 6 }) {
      if (node.dir) {
        SymbolGlyph(this.expanded.indexOf(node.path) >= 0 ? $r('sys.symbol.chevron_down')
          : $r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([this.p().textTertiary])
      } else {
        Circle({ width: 3, height: 3 })
          .fill(node.path === this.current ? this.p().brand : this.p().textTertiary)
      }
      Text(node.name)
        .fontSize(13)
        .fontColor(node.path === this.current ? this.p().brand : this.p().textPrimary)
        .fontWeight(node.path === this.current ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(34)
    .padding({ left: 10 + node.depth * 14, right: 10 })
    .borderRadius(8)
    .backgroundColor(node.path === this.current ? this.p().brandSoft : Color.Transparent)
    .onClick(() => {
      if (node.dir) {
        this.toggle(node.path);
      } else {
        this.onOpen(node.path);
      }
    })
    .bindContextMenu(this.TreeMenu(node), ResponseType.LongPress)
  }

  // Same menu as a directory row, aimed at the project root itself.
  @Builder
  RootMenu() {
    Menu() {
      MenuItem({ content: '新建文件' })
        .onClick(() => {
          this.fileDir = '';
          this.fileName = '';
          this.fileNaming = true;
        })
      MenuItem({ content: '导入文件' })
        .onClick(() => {
          this.onImportFiles('');
        })
    }
  }

  // Long press, not swipe: a swipe on a two-line tree row fights the pane's own gesture,
  // and deleting source files is the one action that must not be a reflex.
  @Builder
  TreeMenu(node: Node) {
    Menu() {
      if (node.dir) {
        MenuItem({ content: '新建文件' })
          .onClick(() => {
            this.fileDir = node.path;
            this.fileName = '';
            this.fileNaming = true;
          })
        MenuItem({ content: '导入文件' })
          .onClick(() => {
            this.onImportFiles(node.path);
          })
      } else {
        MenuItem({ content: '删除文件' })
          .onClick(() => {
            this.confirmDeleteFile(node.path);
          })
      }
    }
  }

  private confirmDeleteFile(rel: string): void {
    AlertDialog.show({
      title: '删除文件',
      message: '删除「' + rel + '」？无法恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E5484D',
        action: () => {
          this.onDeleteFile(rel);
        }
      }
    });
  }

  @Builder
  NewFileSheet() {
    Column({ space: 12 }) {
      Text('在 ' + (this.fileDir.length === 0 ? '根目录' : this.fileDir) + ' 新建文件')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().textPrimary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      TextInput({ text: this.fileName, placeholder: '文件名，如 index.ets' })
        .height(44)
        .width('100%')
        .fontSize(15)
        .fontColor(this.p().textPrimary)
        .placeholderColor(this.p().textTertiary)
        .backgroundColor(this.p().card)
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.fileName = v;
        })
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(this.p().textSecondary)
          .layoutWeight(1)
          .height(44)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.p().card)
          .onClick(() => {
            this.fileNaming = false;
          })
        Text('创建')
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .layoutWeight(1)
          .height(44)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.p().brandSoft)
          .onClick(() => {
            const name = this.fileName.trim();
            this.fileNaming = false;
            if (name.length > 0) {
              this.onCreateFile(this.fileDir, name);
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
  }

  @Builder
  Explorer() {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(13)
          .fontColor([this.p().textSecondary])
        Text(this.project.length === 0 ? '未打开工程' : this.project)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.project.length > 0) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(14)
            .fontColor([this.p().textSecondary])
            .padding(6)
            .onClick(() => {
              this.onRefresh();
            })
        }
      }
      .width('100%')
      .height(34)
      .padding({ left: 10, right: 10 })
      .bindContextMenu(this.RootMenu(), ResponseType.LongPress)

      ForEach(flattenTree(this.files, this.expanded), (node: Node) => {
        this.TreeRow(node)
      }, (node: Node) => node.path + ':' + node.depth)
    }
    .width('100%')
  }

  @Builder
  Outline() {
    Column() {
      if (this.outlineNote.length > 0) {
        Text(this.outlineNote)
          .fontSize(12)
          .fontColor(this.p().textTertiary)
          .width('100%')
          .padding({ left: 14, top: 10 })
      }
      ForEach(this.outline, (name: string) => {
        Row({ space: 6 }) {
          Circle({ width: 3, height: 3 })
            .fill(this.p().textTertiary)
          Text(name)
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(28)
        .padding({ left: 14, right: 10 })
      }, (name: string) => name)
    }
    .width('100%')
  }

  @Builder
  NameSheet() {
    Column({ space: 12 }) {
      Text('新建工程')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().textPrimary)
        .width('100%')
      TextInput({ text: this.newName, placeholder: '工程名' })
        .height(44)
        .width('100%')
        .fontSize(15)
        .fontColor(this.p().textPrimary)
        .placeholderColor(this.p().textTertiary)
        .backgroundColor(this.p().card)
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.newName = v;
        })
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(this.p().textSecondary)
          .layoutWeight(1)
          .height(44)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.p().card)
          .onClick(() => {
            this.naming = false;
          })
        Text('创建')
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .layoutWeight(1)
          .height(44)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.p().brandSoft)
          .onClick(() => {
            const name = this.newName.trim();
            this.naming = false;
            if (name.length > 0) {
              this.onCreate(name);
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  @Builder
  DeviceView() {
    Column({ space: 6 }) {
      Text('通道')
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .width('100%')
      Text(this.device)
        .fontSize(13)
        .fontColor(this.p().textPrimary)
        .width('100%')
      Text(this.linkState.length === 0 ? '未连接' : this.linkState)
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .width('100%')
      Text('签名')
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .width('100%')
        .margin({ top: 8 })
      Text(this.agcState.length === 0 ? 'AGC 未查询' : this.agcState)
        .fontSize(13)
        .fontColor(this.p().textPrimary)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 10 })
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        this.ViewIcon($r('sys.symbol.folder'), 0)
        this.ViewIcon($r('sys.symbol.list_bullet'), 1)
        this.ViewIcon($r('sys.symbol.link'), 2)
        Blank()
        Stack() {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(16)
            .fontColor([this.p().textSecondary])
        }
        .width(32)
        .height(32)
        .borderRadius(8)
        .onClick(() => {
          this.onSettings();
        })

        Stack() {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
            .fontSize(16)
            .fontColor([this.p().textSecondary])

        }
        .width(32)
        .height(32)
        .borderRadius(8)
        .bindMenu(this.menuItems())
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 8 })
      .alignItems(VerticalAlign.Center)

      Divider().color(this.p().divider)

      Scroll() {
        Column() {
          if (this.view === 0) {
            this.Explorer()
          } else if (this.view === 1) {
            this.Outline()
          } else {
            this.DeviceView()
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width(this.paneWidth)
    .height('100%')
    // Material alone leaves the drawer see-through over the editor on this device, which
    // puts the tree on top of the code; the plate carries an opaque surface underneath.
    .backgroundColor(this.p().surface)
    .systemMaterial(PANE_MATERIAL)
    .border({ width: 0.5, color: glassEdge(this.dark) })
    .borderRadius(RADIUS)
    .clip(true)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -24 })))
    .bindSheet($$this.fileNaming, this.NewFileSheet(), {
      height: 240,
      dragBar: false,
      showClose: false,
      onDisappear: () => {
        this.fileNaming = false;
      }
    })
    .bindSheet($$this.naming, this.NameSheet(), {
      height: 196,
      dragBar: true,
      showClose: false,
      backgroundColor: this.p().pane,
      onDisappear: () => {
        this.naming = false;
      }
    })
  }
}

// Source tree. Expanded width shows it; collapsed it is a 16vp drag strip.
@Component
export struct RightRail {
  @Prop dark: boolean = true;
  @Prop files: string[] = [];
  @Prop current: string = '';
  @Link rightOpen: boolean;
  onOpen: (rel: string) => void = () => {
  };
  onExpanded: () => void = () => {
  };

  private p(): Palette {
    return palette(this.dark);
  }

  build() {
    Column() {
      if (this.rightOpen) {
        List({ space: 2 }) {
          ForEach(this.files, (item: string) => {
            ListItem() {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(16)
                  .fontColor([item === this.current ? this.p().brand : this.p().textTertiary])
                Text(lastSegment(item))
                  .fontSize(13)
                  .fontColor(item === this.current ? this.p().brand : this.p().textPrimary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .height(40)
              .padding({ left: 12, right: 12 })
              .borderRadius(10)
              .backgroundColor(item === this.current ? this.p().brandSoft : Color.Transparent)
            }
            .onClick(() => {
              this.onOpen(item);
            })
          }, (item: string) => item)
        }
        .width('100%')
        .height('100%')
      } else {
        // Collapsed: Monaco's own minimap is the content; the strip only catches drags.
        Blank()
      }
    }
    .width(this.rightOpen ? 220 : 16)
    .height('100%')
    .backgroundColor(this.rightOpen ? this.p().pane : Color.Transparent)
    .borderRadius(RADIUS)
    .border({ width: this.rightOpen ? 1 : 0, color: this.p().divider })
    .clip(true)
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionEnd((e: GestureEvent) => {
          animateTo({ duration: DURATION, curve: spring() }, () => {
            if (e.offsetX < -40) {
              this.rightOpen = true;
            } else if (e.offsetX > 40) {
              this.rightOpen = false;
            }
          });
          this.onExpanded();
        })
    )
  }
}

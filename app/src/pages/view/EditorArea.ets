import web_webview from '@ohos.web.webview';
import { DURATION, spring } from '../model/Motion';
import { palette, Palette, RADIUS } from '../model/Palette';
import { EditorBridge } from '../model/Bridge';
import { fileSize, isBinaryFile, isImageFile, isProtectedProject, projectDir } from '../model/Project';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import { LeftPane, RightRail } from './SidePanes';

function formatBytes(n: number): string {
  if (n < 1024) {
    return n + ' B';
  }
  if (n < 1024 * 1024) {
    return (n / 1024).toFixed(1) + ' KB';
  }
  return (n / 1024 / 1024).toFixed(1) + ' MB';
}

// The workspace proper: the editor card, the tree rail that floats over its right edge,
// and the project menu that covers the left. The page owns the state; this component only
// lays the three out and forwards the gestures.
@Component
export struct EditorArea {
  @Prop dark: boolean = true;
  // Only the phone shape opens the menu as a drawer; the wider shapes park it in the flow.
  @Prop compact: boolean = true;
  @StorageProp('ide.project') project: string = '';
  @StorageProp('ide.projects') projects: string[] = [];
  @Prop files: string[] = [];
  @Prop @Watch('onCurrentChanged') current: string = '';
  @Prop device: string = '';
  @Link leftOpen: boolean;
  @Link rightOpen: boolean;
  controller: web_webview.WebviewController = new web_webview.WebviewController();
  bridge: EditorBridge = new EditorBridge();
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
  onDeleteProject: (name: string) => void = () => {
  };
  onSettings: () => void = () => {
  };
  // The drawer mounted inside the editor needs the same chat entry as the one mounted by the page:
  // two mounts of one component must not disagree about which icons work.
  onChat: () => void = () => {
  };
  onRail: () => void = () => {
  };
  onRefresh: () => void = () => {
  };

  // Decoded once per switch: a file:// URL handed to Image does not resolve for a path
  // inside the app sandbox, so the bitmap is read through its descriptor instead.
  @State private pixmap: image.PixelMap | undefined = undefined;
  // The naming sheet for a new project, owned here so the empty state can create one without
  // routing through the drawer that happens to be closed.
  @State private naming: boolean = false;
  @State private newName: string = '';
  // Which project row is under the finger, so the press state can be drawn from state rather than
  // from a hover animation that the phone shape never fires.
  @State private pressed: string = '';

  private p(): Palette {
    return palette(this.dark);
  }

  // The watcher only fires on change; a session restored onto a bitmap never changes.
  aboutToAppear(): void {
    this.onCurrentChanged();
  }

  private onCurrentChanged(): void {
    this.pixmap = undefined;
    if (this.project.length === 0 || !isImageFile(projectDir(this.project), this.current)) {
      return;
    }
    try {
      const file = fs.openSync(projectDir(this.project) + '/' + this.current, fs.OpenMode.READ_ONLY);
      const source = image.createImageSource(file.fd);
      source.createPixelMap().then((pm: image.PixelMap) => {
        this.pixmap = pm;
        fs.closeSync(file);
      }).catch(() => {
        fs.closeSync(file);
      });
    } catch (e) {
      this.pixmap = undefined;
    }
  }

  private closeMenu(): void {
    animateTo({ duration: DURATION, curve: spring() }, () => {
      this.leftOpen = false;
    });
  }

  // The swipe reveal on a project row. Tapping it runs through the same confirmation the
  // full swipe does, so both routes end in the dialog.
  @Builder
  DeleteSwipe(name: string) {
    Row() {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(16)
        .fontColor([Color.White])
    }
    .width(76)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#E5484D')
    .onClick(() => {
      this.confirmDelete(name);
    })
  }

  private confirmDelete(name: string): void {
    AlertDialog.show({
      title: '删除工程',
      message: '删除「' + name + '」？工程目录会一起删掉，无法恢复。',
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
          this.onDeleteProject(name);
        }
      }
    });
  }

  // Nothing open is a state of its own: an empty editor invites typing into a buffer that
  // has no file behind it.
  @Builder
  Empty() {
    Column({ space: 18 }) {
      Blank()
      Text('hvolt IDE')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().textPrimary)
      Text(this.projects.length === 0 ? '还没有工程' : '选择要打开的工程')
        .fontSize(13)
        .fontColor(this.p().textTertiary)

      Column({ space: 8 }) {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(17)
            .fontColor([this.p().brand])
          Text('打开工程')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .borderRadius(14)
        .backgroundColor(this.p().card)
        .onClick(() => {
          this.onOpenProject();
        })

        // Creating a project belongs on this page, not only behind the drawer: the empty state is
        // where a first-run reader lands, and it should not require opening a menu to start.
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.plus_square'))
            .fontSize(17)
            .fontColor([this.p().brand])
          Text('新建工程')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .borderRadius(14)
        .backgroundColor(this.p().card)
        .onClick(() => {
          this.newName = '';
          this.naming = true;
        })

        if (this.projects.length > 0) {
          List() {
            ForEach(this.projects, (name: string) => {
              ListItem() {
                Row() {
                  Text(name)
                    .fontSize(14)
                    .fontColor(this.pressed === name ? this.p().textPrimary : this.p().textSecondary)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .height(44)
                .padding({ left: 14, right: 14 })
                // A row that looks inert gets long-pressed by accident; the press state is what
                // tells the reader the tap landed before the project has finished loading.
                .backgroundColor(this.pressed === name ? this.p().brandSoft : Color.Transparent)
                .scale({ x: this.pressed === name ? 0.98 : 1, y: this.pressed === name ? 0.98 : 1 })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressed = name;
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressed = '';
                  }
                })
                .animation({ duration: 120, curve: spring() })
                .onClick(() => {
                  this.onSwitch(name);
                })
              }
              // The embedded self-bootstrap project has no delete affordance at all, not even the
              // swipe that would reveal one: the app builds itself from that directory, so a
              // gesture that offers to remove it is a promise the app cannot keep.
              .swipeAction(isProtectedProject(name) ? { end: undefined } : {
                end: {
                  builder: () => {
                    this.DeleteSwipe(name);
                  },
                  onAction: () => {
                    this.confirmDelete(name);
                  },
                  actionAreaDistance: 76
                }
              })
            }, (name: string) => name)
          }
          .width('100%')
          .height(Math.min(this.projects.length, 5) * 44 + 4)
          .borderRadius(14)
          .backgroundColor(this.p().card)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 380 })

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor(this.p().bg)
    .borderRadius(RADIUS)
    // A rightward swipe on the empty state asks for the harness face. One shot past a threshold:
    // the finger's travel is not tracked.
  }

  // The naming sheet the empty state opens. Deliberately the same shape as the drawer's: two ways
  // to create a project should not look like two different features.
  @Builder
  NameSheet() {
    Column() {
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
      .constraintSize({ maxWidth: 380 })
      .padding({ left: 16, right: 16, top: 12, bottom: 14 })
      .borderRadius(16)
      .backgroundColor(this.p().pane)
      .border({ width: 0.5, color: this.p().divider })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // The scrim is a hit target: a sheet with no way out but a button traps the reader when the
    // keyboard is covering the button.
    .backgroundColor('#00000066')
    .onClick(() => {
      this.naming = false;
    })
  }

  // Bitmaps are shown, not opened: the file never becomes a text buffer, so nothing can be
  // written back over its bytes.
  @Builder
  Preview() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.photo'))
          .fontSize(13)
          .fontColor([this.p().textSecondary])
        Text(this.current)
          .fontSize(12)
          .fontColor(this.p().textSecondary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatBytes(fileSize(this.project, this.current)))
          .fontSize(11)
          .fontColor(this.p().textTertiary)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 6 })

      Image(this.pixmap)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(this.p().card)
        .borderRadius(12)
        .margin({ left: 12, right: 12, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.p().bg)
    .borderRadius(RADIUS)
  }

  // Binary files get a notice, not a buffer: showing the bytes as text and saving them back
  // would round-trip them through UTF-8.
  @Builder
  BinaryNotice() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.doc_plaintext'))
        .fontSize(28)
        .fontColor([this.p().textTertiary])
      Text(this.current)
        .fontSize(13)
        .fontColor(this.p().textSecondary)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(formatBytes(fileSize(this.project, this.current)) + ' · 二进制文件，不在文本编辑器中打开')
        .fontSize(11)
        .fontColor(this.p().textTertiary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
    .backgroundColor(this.p().bg)
    .borderRadius(RADIUS)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The editor spans the card edge to edge: the rail is an overlay, not a column, so
      // both margins stay equal at every breakpoint.
      if (this.project.length === 0) {
        this.Empty()
      } else if (isImageFile(projectDir(this.project), this.current)) {
        this.Preview()
      } else if (isBinaryFile(projectDir(this.project), this.current)) {
        this.BinaryNotice()
      } else {
        Web({ src: $rawfile('web/index.html'), controller: this.controller })
          .width('100%')
          .height('100%')
          // Without this the web surface flashes its default white while the card resizes.
          .backgroundColor(this.p().bg)
          .borderRadius(RADIUS)
          .clip(true)
          .javaScriptAccess(true)
          .javaScriptProxy({
            object: this.bridge,
            name: 'hvoltBridge',
            methodList: ['save', 'ready', 'dirty', 'position', 'chromeHidden', 'openChat', 'log'],
            controller: this.controller
          })
      }

      // Collapsed it is a 16vp strip whose horizontal drag pulls the file tree out of the
      // right edge; expanded it covers the minimap.
      RightRail({
        dark: this.dark,
        files: this.files,
        current: this.current,
        rightOpen: $rightOpen,
        onOpen: this.onOpen,
        onExpanded: this.onRail
      })
        .align(Alignment.End)

      // A drawer on the phone shape closes when the workspace behind it is touched. It is
      // a hit target only — the drawing keeps the editor at full contrast behind the menu.
      if (this.leftOpen && this.compact) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.closeMenu();
          })
      }

      if (this.naming) {
        this.NameSheet()
      }

      if (this.leftOpen) {
        LeftPane({
          dark: this.dark,
          onChat: this.onChat,
          paneWidth: 232,
          onOpen: this.onOpen,
          onCreate: this.onCreate,
          onSwitch: this.onSwitch,
          onOpenProject: this.onOpenProject,
          onCloseProject: this.onCloseProject,
          onSettings: this.onSettings,
          onRefresh: this.onRefresh
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}

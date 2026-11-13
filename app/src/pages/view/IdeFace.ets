import { GAP, Palette, palette } from '../model/Palette';
import { Bp } from '../model/Bridge';
import { DURATION, spring } from '../model/Motion';
import { Session } from '../model/Session';
import { ChromeBar } from './ChromeBar';
import { ActivityBar } from './ActivityBar';
import { LeftPane } from './SidePanes';
import { EditorArea } from './EditorArea';
import { BottomDock } from './BottomDock';

// IDE 面：标题带、左栏、编辑器、底部状态坞。数据全部来自 Session 与它的 AppStorage 发布点，
// 这里只负责组合与把用户动作转成回调，页面不再持有这棵树里的任何细节。
@Component
export struct IdeFace {
  @Prop dark: boolean = true;
  @Prop bp: Bp = 'compact';
  // 面高：屏幕高减状态栏，由页面算好传进来（'100%' 会停在底部避让上沿）。
  @Prop frameVp: number = 0;
  @Prop statusText: string = '';
  @Prop statusTone: number = 0;
  @Prop log: string = '';
  @Prop hlog: string = '';
  @Prop current: string = '';
  @Prop link: number = 0;
  @Prop linkText: string = '';
  @Prop device: string = '';
  @StorageProp('ide.chromeHidden') chromeHidden: boolean = false;
  @StorageProp('bottomRectHeight') bottomInset: number = 0;

  @Link leftOpen: boolean;
  @Link rightOpen: boolean;
  @Link panelOpen: boolean;
  @Link panelTab: number;

  // 只作引用用：Session 的字段通过 AppStorage 被各面板订阅，这里不参与观测。
  session: Session = new Session();

  onChat: () => void = () => {};
  onSettings: () => void = () => {};
  onBuild: () => void = () => {};
  onCloseTab: (rel: string) => void = () => {};

  private p(): Palette {
    return palette(this.dark);
  }

  private frame(): string | number {
    return this.frameVp > 0 ? this.frameVp : '100%';
  }

  build() {
    Column() {
      ChromeBar({
        dark: this.dark,
        showToggle: this.bp !== 'expanded',
        onToggle: () => {
          animateTo({ duration: DURATION, curve: spring() }, () => {
            this.leftOpen = !this.leftOpen;
          });
        },
        onSelectTab: (rel: string) => {
          this.session.openFile(rel);
        },
        onCloseTab: (rel: string) => {
          this.onCloseTab(rel);
        },
        onBuild: () => {
          this.onBuild();
        },
        onInstall: () => {
          this.session.deploy();
        },
        onStart: () => {
          this.session.launch();
        }
      })

      Row() {
        if (this.bp === 'expanded') {
          ActivityBar({
            dark: this.dark,
            onChat: () => {
              this.onChat();
            },
            onSettings: () => {
              this.onSettings();
            }
          })
        }

        if (this.bp !== 'compact') {
          LeftPane({
            dark: this.dark,
            onChat: () => {
              this.onChat();
            },
            paneWidth: this.bp === 'medium' ? 240 : 260,
            onOpen: (rel: string) => {
              this.session.openFile(rel);
            },
            onCreate: (name: string) => {
              this.session.createProjectNamed(name);
            },
            onSwitch: (name: string) => {
              this.session.openProject(name);
            },
            onOpenDir: () => {
              this.session.importProjectDir();
            },
            onSettings: () => {
              this.onSettings();
            },
            onRefresh: () => {
              this.session.rescan();
            },
            onDeleteFile: (rel: string) => {
              this.session.deleteTreeFile(rel);
            },
            onCreateFile: (dirRel: string, fileName: string) => {
              this.session.createFileIn(dirRel, fileName);
            },
            onImportFiles: (dirRel: string) => {
              this.session.importFilesInto(dirRel);
            }
          })
            .margin({ left: GAP, top: GAP, bottom: GAP })
        }

        EditorArea({
          dark: this.dark,
          compact: this.bp === 'compact',
          leftOpen: $leftOpen,
          rightOpen: $rightOpen,
          controller: this.session.controller,
          bridge: this.session.bridge,
          onOpen: (rel: string) => {
            this.session.openFile(rel);
          },
          onCreate: (name: string) => {
            this.session.createProjectNamed(name);
          },
          onSwitch: (name: string) => {
            this.session.openProject(name);
          },
          onOpenProject: () => {
            this.session.importProjectDir();
          },
          onCloseProject: () => {
            if (!this.session.hasDirtyCurrent()) {
              this.session.closeProject();
              return;
            }
            ActionSheet.show({
              title: '「' + this.session.current + '」有未保存的改动',
              message: '',
              autoCancel: true,
              confirm: {
                value: '保存并关闭工程',
                action: () => {
                  this.session.closeProjectSaving();
                }
              },
              sheets: [
                {
                  title: '不保存并关闭',
                  action: () => {
                    this.session.closeProject();
                  }
                }
              ],
              cancel: () => {
              }
            });
          },
          onDeleteProject: (name: string) => {
            this.session.deleteProject(name);
          },
          onChat: () => {
            this.onChat();
          },
          onSettings: () => {
            this.onSettings();
          },
          onRail: () => {
            this.session.syncChrome();
          },
          onRefresh: () => {
            this.session.rescan();
          }
        })
          .layoutWeight(1)
          .width('calc(100% - ' + (GAP * 2) + 'vp)')
          .margin({ left: GAP, right: GAP, top: this.chromeHidden ? 4 : 0, bottom: 4 })
      }
      .layoutWeight(1)
      .width('100%')

      BottomDock({
        dark: this.dark,
        compact: this.bp === 'compact',
        bottomInset: this.bottomInset,
        statusText: this.statusText,
        log: this.log,
        hlog: this.hlog,
        current: this.current,
        statusTone: this.statusTone,
        link: this.link,
        linkText: this.linkText,
        device: this.device,
        onFilter: (keyword: string, tag: string, level: string) => {
          this.session.logKeywords = keyword.length === 0 ? [] : [keyword];
          this.session.logTag = tag;
          this.session.logLevel = level;
          this.session.startLogStream();
        },
        onDeviceTap: () => {
          this.onSettings();
        },
        panelOpen: $panelOpen,
        panelTab: $panelTab,
        onTab: (idx: number) => {
          if (idx === 1) {
            this.session.startLogStream();
          } else {
            this.session.stopLogStream();
          }
        }
      })
    }
    .width('100%')
    .height(this.frame())
    .alignItems(HorizontalAlign.Start)
  }
}

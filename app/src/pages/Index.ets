import hilog from '@ohos.hilog';
// Entry file: layout and the transient switches only. Everything the shell can do lives
// in ./model/Session; the session publishes its fields to AppStorage and the panes
// subscribe to them, so this file never threads data through intermediate props.
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import web_webview from '@ohos.web.webview';

import { GAP, palette, Palette } from './model/Palette';
import { DURATION, spring } from './model/Motion';
import { Bp } from './model/Bridge';
import { Session } from './model/Session';
import { LayoutWatcher } from './model/Layout';
import { TopBar } from './view/TopBar';
import { ActivityBar } from './view/ActivityBar';
import { LeftPane } from './view/SidePanes';
import { BottomDock } from './view/BottomDock';
import { ChatPanel, ChatLine, FoldMode } from './view/ChatPanel';
import { setChatHandler } from './model/Bridge';
import { LlmConfig, loadLlmConfig } from './harness/loop/Settings';
import { EditorArea } from './view/EditorArea';
import { SettingsSheet } from './view/SettingsSheet';
import { providerOf } from './harness/loop/Urls';

@Entry
@Component
struct Index {
  private session: Session = new Session();
  private layout: LayoutWatcher | undefined = undefined;

  @State bp: Bp = 'compact';
  @State leftOpen: boolean = false;
  @State rightOpen: boolean = false;
  @State panelOpen: boolean = false;
  @State chatOpen: boolean = false;
  @State chatBusy: boolean = false;
  @State chatLines: ChatLine[] = [];
  @State modelLabel: string = '';
  @State providerLabel: string = '';
  @State panelTab: number = 0;
  @State showSettings: boolean = false;
  @State dark: boolean = true;
  @State devList: string[] = [];
  @State link: number = 0;
  @State linkText: string = '';
  @State statusLine: string = '';
  @State logText: string = '';
  @State hlogText: string = '';
  @State devTarget: string = '';
  @State agcText: string = '';
  @State agcUser: string = '';
  @State agcAuthUrl: string = '';
  authController: web_webview.WebviewController = new web_webview.WebviewController();
  // A failed step is the one case where the log has to come forward by itself: the reason
  // lives in the toolchain output, not in the status line.
  @State @Watch('onTone') statusToneValue: number = 0;
  @State screenH: number = 0;
  @StorageProp('topRectHeight') topInset: number = 0;
  @StorageProp('bottomRectHeight') bottomInset: number = 0;
  // Watching it is what repaints the window chrome: the strip above the app belongs to
  // the window, so changing the app palette has to repaint it explicitly.
  @StorageProp('appearance') @Watch('onAppearance') appearance: number = 0;
  @StorageProp('ide.chromeHidden') chromeHidden: boolean = false;
  @StorageProp('ide.current') currentRel: string = '';
  @StorageProp('ide.project') projectName: string = '';
  @StorageProp('autodeploy') autoDeploy: string = '0';

  // 0 follows the system, 1 forces dark, 2 forces light.
  private isDark(): boolean {
    if (this.appearance === 1) {
      return true;
    }
    if (this.appearance === 2) {
      return false;
    }
    return this.dark;
  }

  private p(): Palette {
    return palette(this.isDark());
  }

  // The single publication point: every pane reads these keys, so a new value reaches
  // the status bar, the sheet and the menu without new plumbing.
  private publish(): void {
    const s = this.session;
    AppStorage.setOrCreate('ide.files', s.files);
    AppStorage.setOrCreate('ide.tabs', s.openTabs);
    AppStorage.setOrCreate('ide.dirty', s.dirtyTabs);
    AppStorage.setOrCreate('ide.current', s.current);
    AppStorage.setOrCreate('ide.pos', s.curLine + ',' + s.curCol);
    AppStorage.setOrCreate('ide.chromeHidden', s.chromeHidden);
    AppStorage.setOrCreate('ide.projects', s.projects);
    AppStorage.setOrCreate('ide.project', s.project);
    AppStorage.setOrCreate('ide.device', s.device);
    this.devList = s.devices;
    AppStorage.setOrCreate('ide.status', s.statusText);
    AppStorage.setOrCreate('ide.tone', s.statusTone);
    AppStorage.setOrCreate('ide.log', s.log);
    AppStorage.setOrCreate('ide.hlog', s.hlog);
    AppStorage.setOrCreate('ide.link', s.linkState);
    this.link = s.link;
    this.linkText = s.linkState;
    this.statusLine = s.statusText;
    this.logText = s.log;
    this.hlogText = s.hlog;
    this.devTarget = s.device;
    this.agcText = s.agc.state;
    this.agcUser = s.agc.user;
    this.agcAuthUrl = s.agc.url;
    this.statusToneValue = s.statusTone;
    AppStorage.setOrCreate('ide.outline', s.outline);
    AppStorage.setOrCreate('ide.outlineNote', s.outlineNote);
    AppStorage.setOrCreate('ide.agc', s.agc.state);
    AppStorage.setOrCreate('ide.busy', s.busy);
    AppStorage.setOrCreate('ide.projectInfo',
      s.project + ' · ' + s.sourceCount + ' 个源文件\n' + s.projectPath());
    AppStorage.setOrCreate('ide.signingInfo',
      (s.signingReady ? '调试签名材料已就位' : '未找到签名材料') + '\n' + s.agc.state);
    AppStorage.setOrCreate('ide.aboutInfo', s.version);
  }

  aboutToAppear(): void {
    // Shrinking the page instead of lifting it: with OFFSET the whole surface (header included)
    // slides up when the keyboard opens, which is what made the title look wrong.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.refreshScreenHeight();
    // Rotating the device changes the height frame() subtracts the inset from; without this the
    // page keeps the portrait edge and leaves a band at the bottom.
    try {
      window.getLastWindow(this.getUIContext().getHostContext() as common.UIAbilityContext).then((w) => {
        // The manifest entry for orientation is not honoured by this build chain, so the window
        // is told directly. Restricted rather than forced: the system rotation lock still wins.
        try {
          w.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
        } catch (e) {
        }
        w.on('windowSizeChange', () => {
          this.refreshScreenHeight();
        });
      }).catch(() => {
      });
    } catch (e) {
    }
    this.session.onChange = () => {
      this.publish();
      this.syncChatFromHistory();
    };
    loadLlmConfig().then((config: LlmConfig) => {
      this.modelLabel = config.model;
      this.providerLabel = providerOf(config.baseUrl);
    }).catch(() => {
    });
    setChatHandler(() => {
      animateTo({ duration: DURATION, curve: spring() }, () => {
        this.chatOpen = true;
      });
    });
    this.session.start(() => {
      this.publish();
    });
    this.layout = new LayoutWatcher(
      (bp: Bp) => {
        this.applyBp(bp);
      },
      (dark: boolean) => {
        this.dark = dark;
        this.session.dark = dark;
        this.session.syncChrome();
        this.paintSystemBar();
      });
    this.layout.start();
    this.paintSystemBar();
    this.publish();
  }

  // The hilog tab keeps a device round trip running; leaving it running in the background
  // means the shell keeps polling the device while the user is elsewhere.
  onPageHide(): void {
    this.session.stopLogStream();
  }

  onPageShow(): void {
    if (this.panelOpen && this.panelTab === 1) {
      this.session.startLogStream();
    }
  }

  aboutToDisappear(): void {
    this.session.stopLogStream();
    if (this.layout !== undefined) {
      this.layout.stop();
    }
  }

  // "100%" resolves inside the safe area; the page origin already sits below the status
  // bar, so the frame is the physical height minus that inset.
  private refreshScreenHeight(): void {
    try {
      this.screenH = px2vp(display.getDefaultDisplaySync().height);
    } catch (e) {
      this.screenH = 0;
    }
  }

  private frame(): string | number {
    return this.screenH > 0 ? this.screenH - this.topInset : '100%';
  }

  private applyBp(bp: Bp): void {
    if (this.bp === bp) {
      return;
    }
    this.bp = bp;
    animateTo({ duration: DURATION, curve: spring() }, () => {
      if (bp === 'expanded') {
        this.leftOpen = true;
        this.rightOpen = true;
        this.panelOpen = true;
      } else if (bp === 'medium') {
        this.leftOpen = false;
        this.rightOpen = false;
        this.panelOpen = true;
      } else {
        this.leftOpen = false;
        this.rightOpen = false;
        this.panelOpen = false;
      }
    });
  }

  private appendChat(kind: string, text: string): void {
    const lines: ChatLine[] = this.chatLines.slice();
    const last = lines.length > 0 ? lines[lines.length - 1] : undefined;

    if (kind === 'text') {
      if (last !== undefined && last.kind === 'assistant') {
        lines[lines.length - 1] = { kind: 'assistant', text: last.text + text, name: '' };
      } else {
        lines.push({ kind: 'assistant', text: text, name: '' });
      }
      this.chatLines = lines;
      return;
    }
    if (kind === 'thought') {
      if (last !== undefined && last.kind === 'thought') {
        lines[lines.length - 1] = { kind: 'thought', text: last.text + text, name: '' };
      } else {
        lines.push({ kind: 'thought', text: text, name: '' });
      }
      this.chatLines = lines;
      return;
    }
    if (kind === 'tool') {
      // "name args" from the loop: the name is what the process line shows, the args are detail.
      const cut = text.indexOf(' ');
      const name = cut > 0 ? text.substring(0, cut) : text;
      const args = cut > 0 ? text.substring(cut + 1) : '';
      lines.push({ kind: 'tool', text: args, name: name });
    } else if (kind === 'result') {
      const name = last !== undefined && last.kind === 'tool' ? last.name : '';
      lines.push({ kind: 'tool', text: text, name: name });
    } else if (kind === 'error') {
      lines.push({ kind: 'error', text: text, name: '' });
    } else if (kind === 'stats') {
      lines.push({ kind: 'stats', text: text, name: '' });
    } else if (kind === 'user') {
      lines.push({ kind: 'user', text: text, name: '' });
    }
    this.chatLines = lines;
  }

  /** Rebuilds the transcript from session history: a restore, or a project switch. */
  private syncChatFromHistory(): void {
    const lines: ChatLine[] = [];
    for (const message of this.session.chat.messages()) {
      if (message.role === 'system') {
        continue;
      }
      if (message.role === 'user') {
        lines.push({ kind: 'user', text: message.content, name: '' });
      } else if (message.role === 'assistant') {
        if (message.reasoning.length > 0) {
          lines.push({ kind: 'thought', text: message.reasoning, name: '' });
        }
        if (message.content.length > 0) {
          lines.push({ kind: 'assistant', text: message.content, name: '' });
        }
      } else if (message.role === 'tool') {
        lines.push({ kind: 'tool', text: message.content, name: '' });
      }
    }
    this.chatLines = lines;
  }

  private chatMode(): FoldMode {
    const raw = AppStorage.get<string>('chatmode') ?? 'normal';
    if (raw === 'quiet' || raw === 'detail' || raw === 'full') {
      return raw as FoldMode;
    }
    return 'normal';
  }

  private sendChat(text: string, images: string[]): void {
    this.appendChat('user', text);
    this.chatBusy = true;
    this.session.chatSend(text, images, (kind: string, body: string) => {
      this.appendChat(kind, body);
      if (kind === 'done') {
        this.chatBusy = false;
      }
    }).then(() => {
      this.chatBusy = false;
    }).catch((e: Error) => {
      this.chatBusy = false;
      hilog.error(0x0000, 'hvoltide', 'chat turn failed: %{public}s', e.stack === undefined ? e.message : e.stack);
      this.appendChat('error', e.message);
    });
  }

  onTone(): void {
    if (this.statusToneValue === 3 && !this.panelOpen) {
      animateTo({ duration: DURATION, curve: spring() }, () => {
        this.panelOpen = true;
        this.panelTab = 0;
      });
    }
  }

  // project › path › file, the same trail the drawing puts under the tab strip
  private crumbs(): string[] {
    const out: string[] = [];
    if (this.projectName.length > 0) {
      out.push(this.projectName);
    }
    if (this.currentRel.length === 0) {
      return out;
    }
    const parts = this.currentRel.split('/');
    for (let i = 0; i < parts.length; i++) {
      out.push(parts[i]);
    }
    return out;
  }

  // The strip above the bar is the window's status area, so its colour is set on the
  // window rather than approximated with padding or an extra plate.
  onAppearance(): void {
    this.paintSystemBar();
  }

  private async paintSystemBar(): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      await win.setWindowSystemBarProperties({
        statusBarColor: this.p().bg,
        statusBarContentColor: this.isDark() ? '#F3F5F7' : '#111827'
      });
    } catch (e) {
      console.error('status bar: ' + JSON.stringify(e));
    }
  }

  private buildProject(): void {
    this.session.build((code: number) => {
      this.session.loadOutline();
      if (code === 0 && this.autoDeploy === '1') {
        this.session.deploy();
        return;
      }
      animateTo({ duration: DURATION, curve: spring() }, () => {
        this.panelOpen = true;
        this.panelTab = 0;
      });
    });
  }

  // Back walks the shell's own layers before it means "leave the app": a full-screen pane
  // is closed first, so a hardware or gesture back never drops the user out mid-task.
  onBackPress(): boolean {
    if (this.agcAuthUrl.length > 0) {
      this.session.agc.url = '';
      this.agcAuthUrl = '';
      return true;
    }
    if (this.showSettings) {
      this.showSettings = false;
      return true;
    }
    if (this.panelOpen) {
      this.panelOpen = false;
      return true;
    }
    if (this.rightOpen) {
      this.rightOpen = false;
      this.session.syncChrome();
      return true;
    }
    if (this.leftOpen && this.bp === 'compact') {
      this.leftOpen = false;
      this.session.syncChrome();
      return true;
    }
    return false;
  }

  /** Closing a dirty tab asks first: saving, discarding, or leaving it alone. */
  private requestCloseTab(rel: string): void {
    if (!this.session.isDirtyTab(rel)) {
      this.session.closeTab(rel);
      return;
    }
    ActionSheet.show({
      title: '「' + rel + '」有未保存的改动',
      message: '',
      autoCancel: true,
      confirm: {
        value: '保存并关闭',
        action: () => {
          this.session.closeTabSaving(rel);
        }
      },
      sheets: [
        {
          title: '不保存',
          action: () => {
            this.session.discardTab(rel);
          }
        }
      ],
      cancel: () => {
      }
    });
  }

  /** Toolbar and breadcrumb: the strip that stays put above every pane. */
  @Builder
  Chrome() {
    Row() {
      Column() {
        TopBar({
      dark: this.isDark(),
      showToggle: this.bp !== 'expanded',
      onToggle: () => {
        animateTo({ duration: DURATION, curve: spring() }, () => {
          this.leftOpen = !this.leftOpen;
        });
      },
      onSelect: (rel: string) => {
        this.session.openFile(rel);
      },
      onClose: (rel: string) => {
        this.requestCloseTab(rel);
      },
      onBuild: () => {
        this.buildProject();
      },
      onInstall: () => {
        this.session.deploy();
      },
      onStart: () => {
        this.session.launch();
      }
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


  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.p().bg)

      Column() {
      this.Chrome()

        Row() {
          if (this.bp === 'expanded') {
            ActivityBar({
              dark: this.isDark(),
              onSettings: () => {
                animateTo({ duration: DURATION, curve: spring() }, () => {
                  this.showSettings = true;
                });
              }
            })
          }

          if (this.bp !== 'compact') {
            LeftPane({
              dark: this.isDark(),
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
                this.showSettings = true;
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
          dark: this.isDark(),
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
          onSettings: () => {
            animateTo({ duration: DURATION, curve: spring() }, () => {
              this.showSettings = true;
            });
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
          dark: this.isDark(),
          compact: this.bp === 'compact',
          bottomInset: this.bottomInset,
          statusText: this.statusLine,
          log: this.logText,
          hlog: this.hlogText,
          current: this.currentRel,
          statusTone: this.statusToneValue,
          link: this.link,
          linkText: this.linkText,
          device: this.session.device,
          onFilter: (keyword: string, tag: string, level: string) => {
            this.session.logKeywords = keyword.length === 0 ? [] : [keyword];
            this.session.logTag = tag;
            this.session.logLevel = level;
            this.session.startLogStream();
          },
          onDeviceTap: () => {
            animateTo({ duration: DURATION, curve: spring() }, () => {
              this.showSettings = true;
            });
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

      if (this.showSettings) {
        SettingsSheet({
          dark: this.isDark(),
          project: AppStorage.get<string>('ide.project') ?? '',
          device: this.devTarget,
          linkState: AppStorage.get<string>('ide.link') ?? '',
          agcState: this.agcText,
          agcUser: this.agcUser,
          aboutInfo: AppStorage.get<string>('ide.aboutInfo') ?? '',
          busy: this.session.busy,
          onOptions: () => {
            this.session.applyOptions();
          },
          onClose: () => {
            animateTo({ duration: DURATION, curve: spring() }, () => {
              this.showSettings = false;
            });
          },
          onPickProject: () => {
            animateTo({ duration: DURATION, curve: spring() }, () => {
              this.showSettings = false;
              this.leftOpen = true;
            });
          },
          onDevice: (value: string) => {
            this.session.saveDevice(value);
          },
          devices: this.devList,
          link: this.link,
          onAgcLogin: () => {
            this.session.agc.start();
          },
          onAgcLogout: () => {
            this.session.agc.logout();
          },
          onDevices: (list: string[]) => {
            this.session.saveDevices(list);
          }
        })
      }

        if (this.agcAuthUrl.length > 0) {
          // The authorization page runs inside the app: the redirect it makes to loopback
          // carries the tempToken, and intercepting it here keeps the whole exchange in
          // the sandbox instead of relying on an external browser.
          Column() {
            Row({ space: 8 }) {
              Text('AppGallery Connect 登录')
                .fontSize(15)
                .fontColor(this.p().textPrimary)
                .layoutWeight(1)
              Text('取消')
                .fontSize(14)
                .fontColor(this.p().brand)
                .onClick(() => {
                  this.session.agc.url = '';
                  this.agcAuthUrl = '';
                })
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })

            Web({ src: this.agcAuthUrl, controller: this.authController })
              .width('100%')
              .layoutWeight(1)
              .javaScriptAccess(true)
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.p().bg)
        }

      // The chat surface covers everything, including the AGC sheet: it is a mode, not a pane.
      if (this.chatOpen) {
        ChatPanel({
          dark: this.isDark(),
          mode: this.chatMode(),
          project: this.session.project,
          provider: this.providerLabel,
          model: this.modelLabel,
          files: this.session.files,
          lines: $chatLines,
          busy: $chatBusy,
          actions: {
            send: (text: string, images: string[]) => {
              this.sendChat(text, images);
            },
            stop: () => {
              this.session.chatStop();
            },
            reset: () => {
              this.session.chatReset();
              this.chatLines = [];
            },
            close: () => {
              animateTo({ duration: DURATION, curve: spring() }, () => {
                this.chatOpen = false;
              });
            }
          }
        })
          .transition(TransitionEffect.translate({ x: '100%' }).animation({ duration: 220, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height(this.frame())
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

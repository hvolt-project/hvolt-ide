import hilog from '@ohos.hilog';
// Entry file: layout and the transient switches only. Everything the shell can do lives
// in ./model/Session; the session publishes its fields to AppStorage and the panes
// subscribe to them, so this file never threads data through intermediate props.
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import web_webview from '@ohos.web.webview';

import { AskQuestion } from './model/Ask';
import { GAP, palette, Palette } from './model/Palette';
import { DURATION, spring, TURN, TURN_DECIDE, TURN_VISIBLE, TURN_OVERSHOOT, TURN_SHOOT_MS, TURN_SETTLE_MS, TURN_FINGERS_MIN, TURN_FINGERS_MAX } from './model/Motion';
import { Bp } from './model/Bridge';
import { Session } from './model/Session';
import { readPref, writePref } from './model/Prefs';
import { LayoutWatcher } from './model/Layout';
import { IdeFace } from './view/IdeFace';
import { ChatPanel, ChatLine } from './view/ChatPanel';
import { makeLine } from './view/ChatBlocks';
import { setChatHandler } from './model/Bridge';
import { LlmConfig, loadLlmConfig } from './harness/loop/Settings';
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
  // The two faces of the app: the IDE (blank page and editor) and the harness (chat).
  @State chatOpen: boolean = false;
  // 两面翻转：0 = IDE 面，±180 = harness 面。跟手 1:1，屏宽映射 180°；符号由滑向定。
  @State flipAngle: number = 0;
  @State faceHarness: boolean = false;
  // The turn in flight: a second swipe must not read the angle it is animating through.
  @State flipBusy: boolean = false;
  // The angle this drag started from; every update is measured against it, never accumulated.
  private flipBase: number = 0;
  // Set on a start that passed the finger-count gate, so the turn still settles even if a
  // finger leaves mid-drag and the end event reports a different count.
  private flipArmed: boolean = false;
  @State screenW: number = 0;
  @State chatBusy: boolean = false;
  @State chatLines: ChatLine[] = [];
  @State statTurns: number = 0;
  @State statSteps: number = 0;
  @State statTokens: number = 0;
  @State statCache: number = -1;
  @State statPressure: number = 0;
  @State statRate: number = 0;
  /** 键盘顶起的高度；0 表示键盘收起。 */
  @State keyboardHeight: number = 0;
  /**
   * A question a tool is waiting on. Mirrored into state on every session change: reading
   * `session.askQuestion` directly in build() would evaluate once and never re-run when a tool
   * raises one, which is how a pending question became an invisible deadlock.
   */
  @State askQuestions: AskQuestion[] = [];
  @State askIndex: number = 0;
  @State modelLabel: string = '';
  @State providerLabel: string = '';
  @State panelTab: number = 0;
  @State showSettings: boolean = false;
  @State dark: boolean = true;
  @State devList: string[] = [];
  @State link: number = 0;
  @State linkText: string = '';
  @State statusLine: string = '';
  // Status-row figures, mirrored from the model at the same publication point as the rest.
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
    // 回来时停在上次那一面：装包重启后不用每次都手动翻回去。
    readPref('face.harness', '0').then((v: string) => {
      if (v === '1') {
        this.flipAngle = TURN;
        this.faceHarness = true;
        this.chatOpen = true;
      }
    });
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
        w.on('keyboardHeightChange', (h: number) => {
          // 事件给的是 px，padding 要 vp：不换算的话 1099 会被当成三倍屏高的边距。
          this.keyboardHeight = px2vp(h);
          hilog.info(0x0000, 'hvoltide', 'keyboard height: %{public}d px -> %{public}d vp',
            h, this.keyboardHeight);
        });
        // 窗口尺寸变化本身也说明键盘起了：RESIZE 模式下页面高度会减掉键盘。
        w.on('windowSizeChange', () => {
          try {
            const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
            hilog.info(0x0000, 'hvoltide', 'avoid keyboard bottom=%{public}d', area.bottomRect.height);
          } catch (error) {
          }
        });
      }).catch(() => {
      });
    } catch (e) {
    }
    this.session.onChange = () => {
      this.publish();
      this.syncChatFromHistory();
      this.askQuestions = this.session.askQuestions;
      this.askIndex = this.session.askIndex;
    };
    loadLlmConfig().then((config: LlmConfig) => {
      this.modelLabel = config.model;
      this.providerLabel = providerOf(config.baseUrl);
    }).catch(() => {
    });
    setChatHandler((dir: number) => {
      this.flipToDir(dir);
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
      const display0 = display.getDefaultDisplaySync();
      this.screenH = px2vp(display0.height);
      this.screenW = px2vp(display0.width);
    } catch (e) {
      this.screenH = 0;
      this.screenW = 0;
    }
  }

  // 翻到指定面。活动栏图标走这里：不跟手，直接一段完整翻转。
  private flipTo(harness: boolean): void {
    if (this.flipBusy) {
      return;
    }
    this.turnTo(harness ? TURN : 0);
  }

  // 编辑器那一路：WebView 收走触摸，页面松手才上报一次滑向，所以按滑向整段翻。
  // 已经在 harness 面时任意滑向都退回 IDE 面，不区分左右。
  private flipToDir(dir: number): void {
    if (this.flipBusy) {
      return;
    }
    if (Math.abs(this.flipAngle) > 1) {
      this.turnTo(0);
      return;
    }
    this.turnTo(dir < 0 ? -TURN : TURN);
  }

  // 一段完整翻转，两段串联：先快速冲到落点外侧 TURN_OVERSHOOT 度，再从那里沿一条长尾
  // 减速曲线慢慢回到落点。过冲方向由这次行进的方向定，所以进面和退面都朝外侧冲。
  private turnTo(target: number): void {
    this.flipBusy = true;
    const from: number = this.flipAngle;
    const dir: number = target > from ? 1 : (target < from ? -1 : 0);
    const over: number = target + dir * TURN_OVERSHOOT;
    animateTo({ duration: TURN_SHOOT_MS, curve: Curve.FastOutSlowIn }, () => {
      this.flipAngle = over;
      const harness: boolean = Math.abs(target) > 1;
      this.faceHarness = harness;
      this.chatOpen = harness;
      writePref('face.harness', harness ? '1' : '0').catch(() => {
      });
    });
    // 第二段从过冲点单向靠近落点：ExtremeDeceleration 是长尾减速，尾段几乎不走，正好是
    // 「被缓住、慢慢贴合」，而不是来回摆。
    setTimeout(() => {
      animateTo({ duration: TURN_SETTLE_MS, curve: Curve.ExtremeDeceleration }, () => {
        this.flipAngle = target;
      });
    }, TURN_SHOOT_MS);
    setTimeout(() => {
      this.flipBusy = false;
    }, TURN_SHOOT_MS + TURN_SETTLE_MS);
  }

  // 跟手起手。手指数不在三到四之间就不接管这次手势：编辑器与系统的手势要能照常走。
  private flipStart(e: GestureEvent): void {
    if (this.flipBusy || this.flipArmed) {
      return;
    }
    const n: number = e.fingerList ? e.fingerList.length : 0;
    if (n < TURN_FINGERS_MIN || n > TURN_FINGERS_MAX) {
      return;
    }
    this.flipArmed = true;
    this.flipBase = this.flipAngle;
  }

  // 跟手：位移直接映射角度，不做动画，所以手指停住面就停住。
  private flipDrag(e: GestureEvent): void {
    if (!this.flipArmed) {
      return;
    }
    const n: number = e.fingerList ? e.fingerList.length : 0;
    if (n < TURN_FINGERS_MIN || n > TURN_FINGERS_MAX) {
      return;
    }
    const w: number = this.screenW > 0 ? this.screenW : 360;
    const travel: number = (Math.abs(e.offsetX) / w) * TURN;
    let next: number = this.flipBase;
    if (Math.abs(this.flipBase) <= 1) {
      // 从 IDE 面进入：方向由手指决定，左滑取负、右滑取正。
      next = e.offsetX < 0 ? -travel : travel;
    } else {
      // 从 harness 面退出：任意滑向都朝 0 走，省掉「这个方向没反应」的困惑。
      next = this.flipBase + (this.flipBase > 0 ? -travel : travel);
    }
    if (next > TURN) {
      next = TURN;
    }
    if (next < -TURN) {
      next = -TURN;
    }
    this.flipAngle = next;
  }

  // 松手：这次手指走过的路程过阈值就换面，不到就回弹。两个方向都按「走了多少」判，
  // 不按「离 0 还有多远」——后者会让退出要多走 180°−阈值，也就是进出的手感差三倍。
  private flipEnd(): void {
    if (!this.flipArmed) {
      return;
    }
    this.flipArmed = false;
    const a: number = this.flipAngle;
    const moved: number = Math.abs(a - this.flipBase);
    let target: number = this.flipBase;
    if (moved >= TURN_DECIDE) {
      if (Math.abs(this.flipBase) <= 1) {
        // IDE 面：朝手指方向翻过去，符号由滑向定。
        target = a < 0 ? -TURN : TURN;
      } else {
        // harness 面：任意滑向都退回。
        target = 0;
      }
    }
    this.turnTo(target);
  }

  private frame(): string | number {
    // 按屏幕高减状态栏写死，而不是 '100%'：'100%' 参照的是页面布局盒，而布局盒被系统
    // 按底部避让裁掉了 98px，面就停在手势条上沿，底下露出窗口底色。
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
        lines[lines.length - 1] = makeLine('assistant', last.text + text, '');
      } else {
        lines.push(makeLine('assistant', text, ''));
      }
      this.chatLines = lines;
      return;
    }
    if (kind === 'thought') {
      if (last !== undefined && last.kind === 'thought') {
        lines[lines.length - 1] = makeLine('thought', last.text + text, '');
      } else {
        lines.push(makeLine('thought', text, ''));
      }
      this.chatLines = lines;
      return;
    }
    if (kind === 'tool') {
      // "name args" from the loop: the name is what the process line shows, the args are detail.
      const cut = text.indexOf(' ');
      const name = cut > 0 ? text.substring(0, cut) : text;
      const args = cut > 0 ? text.substring(cut + 1) : '';
      lines.push(makeLine('tool', args, name));
    } else if (kind === 'result') {
      const name = last !== undefined && last.kind === 'tool' ? last.name : '';
      lines.push(makeLine('tool', text, name));
    } else if (kind === 'error') {
      lines.push(makeLine('error', text, ''));
    } else if (kind === 'user') {
      lines.push(makeLine('user', text, ''));
    }
    this.chatLines = lines;
    this.syncStats();
  }

  /** 状态栏的数字跟着会话走：每次刷新转写都重取一次。 */
  private syncStats(): void {
    // 状态栏是装饰，不能因为它读不出来就把启动流程打断。
    try {
      const s = this.session.statsForBar();
      this.statTurns = s.turns;
      this.statSteps = s.steps;
      this.statTokens = s.totalTokens;
      this.statCache = s.cacheHit;
      this.statPressure = s.pressure;
      this.statRate = s.rate;
      hilog.info(0x0000, 'hvoltide', 'stats: turns=%{public}d steps=%{public}d tokens=%{public}d cache=%{public}d',
        s.turns, s.steps, s.totalTokens, s.cacheHit);
    } catch (error) {
      const e = error as Error;
      hilog.warn(0x0000, 'hvoltide', 'stats unavailable: %{public}s', e.message === undefined ? 'unknown' : e.message);
    }
  }

  /** Rebuilds the transcript from session history: a restore, or a project switch. */
  private syncChatFromHistory(): void {
    const lines: ChatLine[] = [];
    for (const message of this.session.chat.transcript()) {
      if (message.role === 'user') {
        // 运行时注入不是一个说过的话，但也不是该藏起来的东西：标成 injection 行，可折叠
        if (message.source === 'runtime') {
          lines.push(makeLine('injection', message.content, '上下文'));
          continue;
        }
        lines.push(makeLine('user', message.content, ''));
      } else if (message.role === 'assistant') {
        if (message.reasoning.length > 0) {
          lines.push(makeLine('thought', message.reasoning, ''));
        }
        if (message.content.length > 0) {
          lines.push(makeLine('assistant', message.content, ''));
        }
      } else if (message.role === 'tool') {
        lines.push(makeLine('tool', message.content, ''));
      }
    }
    this.chatLines = lines;
    this.syncStats();
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



  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The gap the box leaves while it turns is painted with the status-bar colour, so the turn
      // reads as the inside of a solid rather than as content floating over nothing.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.p().bg)

      // The IDE face is its own stack so the IDE stays one body under the harness overlay.
      Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.p().bg)

      IdeFace({
        dark: this.isDark(),
        bp: this.bp,
        frameVp: this.screenH > 0 ? this.screenH - this.topInset : 0,
        statusText: this.statusLine,
        statusTone: this.statusToneValue,
        log: this.logText,
        hlog: this.hlogText,
        current: this.currentRel,
        link: this.link,
        linkText: this.linkText,
        device: this.session.device,
        leftOpen: $leftOpen,
        rightOpen: $rightOpen,
        panelOpen: $panelOpen,
        panelTab: $panelTab,
        session: this.session,
        onChat: () => {
          this.flipTo(true);
        },
        onSettings: () => {
          animateTo({ duration: DURATION, curve: spring() }, () => {
            this.showSettings = true;
          });
        },
        onBuild: () => {
          this.buildProject();
        },
        onCloseTab: (rel: string) => {
          this.requestCloseTab(rel);
        }
      })

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

      }
      .width('100%')
      .height(this.frame())
      .shadow({ radius: 22, color: '#00000099', offsetX: 0, offsetY: 0 })
      .rotate({ y: 1, angle: this.flipAngle, perspective: 800 })
      // 只有朝前的面可见。两面都留在树上（不重建），但一面转过 90° 后是背面，露出来只能是
      // 镜像文字，所以按角度切显隐；切换点落在 90° 的薄边上，跟手时看不出跳变。
      .visibility(Math.abs(this.flipAngle) < TURN_VISIBLE ? Visibility.Visible : Visibility.Hidden)
      // 翻转期间把这一面先合成位图再旋转：否则每一帧都要重绘整棵子树（编辑器里是 WebView、
      // chat 里是长列表），内容一多就掉帧。静态时不合并，免得常态下也走离屏渲染。
      .renderGroup(this.flipBusy)

      // The harness face sits over the IDE box, a half revolution away on the same axis.
      // 两面常驻：组件不重建，只改各自角度。
      if (true) {
        ChatPanel({
          dark: this.isDark(),
          keyboardInset: this.keyboardHeight,
          statVisible: this.keyboardHeight <= 0,
          statTurns: this.statTurns,
          statSteps: this.statSteps,
          statTokens: this.statTokens,
          statCache: this.statCache,
          statPressure: this.statPressure,
          statRate: this.statRate,
          project: this.session.project,
          provider: this.providerLabel,
          model: this.modelLabel,
          files: this.session.files,
          askAnswers: this.session.askAnswers,
          lines: $chatLines,
          busy: $chatBusy,
          // Bound to the session, so a question raised by a tool appears without extra plumbing.
          askQuestions: this.askQuestions,
          askIndex: this.askIndex,
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
            answerAsk: (selected: string[], custom: string) => {
              this.session.answerCurrent(selected, custom);
            },
            cancelAsk: () => {
              this.session.cancelAsk();
            },
            listSkills: () => {
              this.session.loadSkill('').then((text: string) => {
                const lines: ChatLine[] = this.chatLines.slice();
                for (const line of text.split('\n')) {
                  lines.push(makeLine('tool', line, 'skill'));
                }
                this.chatLines = lines;
              });
            },
            compact: async () => {
              const outcome = await this.session.chatCompact();
              // 压缩只改模型看到的历史，对话本身照原样留着；结果作为一行工具记录追加。
              const note = makeLine('tool', outcome === null
                ? '无需压缩'
                : '已压缩 seq ' + outcome.from + '-' + outcome.to + '（约 ' + outcome.tokens +
                  ' tokens）', 'compact');
              const lines: ChatLine[] = this.chatLines.slice();
              lines.push(note);
              this.chatLines = lines;
            },
            close: () => {
              // 收回与呼出走同一条翻面：只置 chatOpen 会让角度停在 180，界面看着没动。
              this.flipTo(false);
            }
          }
        })
          .shadow({ radius: 22, color: '#00000099', offsetX: 0, offsetY: 0 })
          // 翻面：harness 面始终比 IDE 面多 180°，两面夹角恒定，跟手时不会出现角度跳变。
          .rotate({ y: 1, angle: this.flipAngle + 180, perspective: 800 })
          // 与 IDE 面同一条规则：只有朝前的一面可见。harness 面在 180° 一侧，所以它露面
          // 的区间与 IDE 面相反。
          .visibility(Math.abs(this.flipAngle) > TURN_VISIBLE ? Visibility.Visible : Visibility.Hidden)
          // 同一条规则：只在翻转期间合并绘制。
          .renderGroup(this.flipBusy)
      }
    }
    .width('100%')
    .height(this.frame())
    .gesture(
      // 三／四指横扫翻面。`fingers` 是最小手指数，五指也会进来，所以回调里按实际指头数过滤。
      PanGesture({ fingers: TURN_FINGERS_MIN, direction: PanDirection.Horizontal })
        .onActionStart((e: GestureEvent) => {
          this.flipStart(e);
        })
        .onActionUpdate((e: GestureEvent) => {
          this.flipDrag(e);
        })
        .onActionEnd((e: GestureEvent) => {
          this.flipEnd();
        })
        .onActionCancel((e: GestureEvent) => {
          this.flipEnd();
        })
    )
    // 整页铺进顶部与底部安全区：背景画到手势条下面，底部那一条由 BottomDock 的状态行自己留。
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

}

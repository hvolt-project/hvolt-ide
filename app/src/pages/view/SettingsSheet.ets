import hilog from '@ohos.hilog';
import { palette, Palette, GAP } from '../model/Palette';
import { importSdk, SdkImportResult, sdkStatus } from '../model/SdkImport';
import { DURATION, spring } from '../model/Motion';
import { connectDevice } from '../model/Actions';
import { writePref } from '../model/Prefs';
import { connectAsync } from '../model/Connect';
import { FILES } from '../model/Stage';
import fs from '@ohos.file.fs';
import { HvoltResult } from '../model/Hvolt';
import { LlmConfig, loadLlmConfig, saveLlmConfig } from '../harness/loop/Settings';
import { loadExtraInstructions, saveExtraInstructions } from '../harness/Prompt';
import { listModels, ModelList } from '../harness/loop/Models';
import {
  FONT_SIZES, KEY_AUTOCONNECT, KEY_AUTOSAVE, KEY_FONT, KEY_LINES, KEY_OBFUSCATE, KEY_TAB,
  KEY_COLLAPSE_TIMING, KEY_SAVE_ON_SWITCH, KEY_TAIL, KEY_TRANSCRIPT_VIEW, KEY_WRAP, TAILS, TAB_SIZES,
  readObfuscation,
  setObfuscation
} from '../model/Options';
import {
  COLLAPSE_TIMINGS, CollapseTiming, collapseTimingLabel, collapseTimingOf, DEFAULT_TRANSCRIPT_VIEW,
  TRANSCRIPT_VIEW_MODES, viewModeLabel, viewModeOf
} from '../model/Policy';

// A switch row: label left, control right, the control writes through immediately.
@Component
struct SwitchRow {
  @Prop dark: boolean = true;
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop value: string = '0';
  onFlip: (on: boolean) => void = () => {
  };

  private p(): Palette {
    return palette(this.dark);
  }

  build() {
    Row() {
      Column({ space: 2 }) {
        Text(this.title).fontSize(15).fontColor(this.p().textPrimary)
        if (this.hint.length > 0) {
          Text(this.hint).fontSize(12).fontColor(this.p().textSecondary)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.value === '1' })
        .selectedColor(this.p().brand)
        .onChange((on: boolean) => {
          this.onFlip(on);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.p().card)
  }
}

// The sheet is a real settings page: every row is a control that changes something in
// the app or in the project, and the only read-only text is the footer line.
@Component
export struct SettingsSheet {
  @Prop dark: boolean = true;
  @Prop project: string = '';
  @Prop device: string = '';
  @Prop linkState: string = '';
  @Prop agcState: string = '';
  @Prop aboutInfo: string = '';
  @Prop busy: boolean = false;
  @Prop agcUser: string = '';
  @Prop devices: string[] = [];
  @Prop link: number = 0;
  // Plain state, filled from AppStorage when the sheet appears: a @StorageProp getter
  // for a key that is not in the store yet takes the whole page down on this device.
  @State private appearance: number = 0;
  /** 工作步骤展示档位。用 @State 而不是每次去读 AppStorage：后者改了不会让组件重渲染，
   *  点完选项看起来像没反应。 */
  @State private transcriptView: string = DEFAULT_TRANSCRIPT_VIEW;
  @State private collapseTiming: string = 'immediate';
  @State private llmBase: string = '';
  @State private llmModel: string = '';
  @State private llmToken: string = '';
  @State private llmEffort: string = '';
  @State private extraPrompt: string = '';
  @State private modelOptions: SelectOption[] = [];
  @State private modelIndex: number = 0;
  @State private modelState: string = '';
  @State private autoDeploy: string = '0';
  @State private fontPx: number = 14;
  @State private lineNumbers: string = '1';
  @State private wordWrap: string = '1';
  @State private tabSize: number = 2;
  @State private autoSave: string = '1';
  @State private obfuscate: string = '0';
  @State private autoConnect: string = '1';
  @State private logTail: number = 120;
  @State private devIp: string = '127.0.0.1';
  @State private devPort: string = '8710';
  @State private devFeedback: string = '';
  @State private curTarget: string = '';
  @State private traceTail: string = '';
  onClose: () => void = () => {
  };
  onDevice: (value: string) => void = () => {
  };
  onOptions: () => void = () => {
  };
  onDevices: (list: string[]) => void = () => {
  };
  onAgcLogin: () => void = () => {
  };
  onAgcLogout: () => void = () => {
  };
  @State private deviceDraft: string = '';
  @State private hint: string = '';
  /** Result of the last SDK import, shown in place of the status while it matters. */
  @State private sdkState: string = '';

  private p(): Palette {
    return palette(this.dark);
  }

  aboutToAppear(): void {
    this.sdkState = sdkStatus();
    this.loadHarnessSettings();
    this.deviceDraft = this.device;
    this.devFeedback = this.linkState;
    this.appearance = AppStorage.get<number>('appearance') ?? 0;
    this.transcriptView = viewModeOf(AppStorage.get<string>(KEY_TRANSCRIPT_VIEW) ?? DEFAULT_TRANSCRIPT_VIEW);
    this.autoDeploy = AppStorage.get<string>('autodeploy') ?? '0';
    this.fontPx = AppStorage.get<number>(KEY_FONT) ?? 14;
    this.lineNumbers = AppStorage.get<string>(KEY_LINES) ?? '1';
    this.wordWrap = AppStorage.get<string>(KEY_WRAP) ?? '1';
    this.tabSize = AppStorage.get<number>(KEY_TAB) ?? 2;
    this.autoSave = AppStorage.get<string>(KEY_AUTOSAVE) ?? '1';
    this.obfuscate = AppStorage.get<string>(KEY_OBFUSCATE) ?? '0';
    this.autoConnect = AppStorage.get<string>(KEY_AUTOCONNECT) ?? '1';
    this.logTail = AppStorage.get<number>(KEY_TAIL) ?? 120;
  }

  // One writer for every option: AppStorage drives the rest of the app, prefs keep it.
  private set(key: string, value: string): void {
    AppStorage.setOrCreate(key, value);
    writePref(key, value);
    this.onOptions();
    this.refresh();
  }

  private refresh(): void {
    this.appearance = AppStorage.get<number>('appearance') ?? 0;
    this.autoDeploy = AppStorage.get<string>('autodeploy') ?? '0';
    this.lineNumbers = AppStorage.get<string>(KEY_LINES) ?? '1';
    this.wordWrap = AppStorage.get<string>(KEY_WRAP) ?? '1';
    this.autoSave = AppStorage.get<string>(KEY_AUTOSAVE) ?? '1';
    this.obfuscate = AppStorage.get<string>(KEY_OBFUSCATE) ?? '0';
    this.autoConnect = AppStorage.get<string>(KEY_AUTOCONNECT) ?? '1';
  }

  private setNumber(key: string, value: number): void {
    AppStorage.setOrCreate(key, value);
    writePref(key, '' + value);
    this.onOptions();
    this.fontPx = AppStorage.get<number>(KEY_FONT) ?? 14;
    this.tabSize = AppStorage.get<number>(KEY_TAB) ?? 2;
    this.logTail = AppStorage.get<number>(KEY_TAIL) ?? 120;
  }

  private addDevice(): void {
    const ip = this.devIp.trim();
    const port = this.devPort.trim();
    if (ip.length === 0 || port.length === 0) {
      this.devFeedback = 'IP 与端口都要填';
      return;
    }
    const addr = ip + ':' + port;
    if (this.devices.indexOf(addr) < 0) {
      this.onDevices(this.devices.concat([addr]));
    }
    this.connectTo(addr);
  }

  private connectTo(addr: string): void {
    this.devFeedback = addr + '  等待设备确认…';
    connectAsync(addr, FILES, (raw: string) => {
      const r: HvoltResult = JSON.parse(raw) as HvoltResult;
      if (r.code === 0) {
        // Success is shown by the row's own subtitle; a banner here would repeat it.
        this.devFeedback = '';
        this.curTarget = addr;
        writePref('device', addr);
        this.onDevice(addr);
      } else {
        this.devFeedback = addr + '  ' + this.reasonOf(r.output);
      }
    });
  }

  private removeDevice(addr: string): void {
    this.onDevices(this.devices.filter((a: string) => a !== addr));
    this.devFeedback = '已移除 ' + addr;
  }

  @Builder
  Section(title: string) {
    Text(title)
      .fontSize(11)
      .fontColor(this.p().textTertiary)
      .width('100%')
      .padding({ left: 4, top: 16, bottom: 6 })
  }

  // Read-only: the SDK is unpacked from the bundled archive on first launch, so this line
  // reports what is on disk rather than offering to change it.
  //
  // 名字必须与 `@State sdkState` 区分开：同名时字段压过方法，调用点拿到的是字符串，
  // 点开设置就抛 TypeError（sdkState is not callable）。字段记的是导入进度，这个方法
  // 读的是磁盘现状，两者语义本来就不同。
  private sdkDiskState(): string {
    const dir = FILES + '/.hvolt/sdk';
    let unpacked = false;
    try {
      unpacked = fs.statSync(dir).isDirectory();
    } catch (e) {
      unpacked = false;
    }
    let stamp = '';
    try {
      stamp = fs.readTextSync(FILES + '/.hvolt/sdk.stamp');
    } catch (e) {
      stamp = '';
    }
    return (unpacked ? '已解包' : '未解包') + ' · 版本 ' + (stamp.length === 0 ? '未知' : stamp);
  }

  private persistLlm(): void {
    const config = new LlmConfig();
    config.baseUrl = this.llmBase;
    config.model = this.llmModel;
    config.token = this.llmToken;
    config.effort = this.llmEffort;
    saveLlmConfig(config);
  }

  private reason(problem: string): string {
    if (problem.indexOf('401') >= 0 || problem.indexOf('403') >= 0) {
      return '密钥不对';
    }
    if (problem.indexOf('404') >= 0) {
      return '没有这个地址';
    }
    if (problem.indexOf('timeout') >= 0 || problem.indexOf('timed out') >= 0) {
      return '连接超时';
    }
    if (problem.indexOf('Failed to connect') >= 0 || problem.indexOf('refused') >= 0) {
      return '连不上';
    }
    return problem;
  }

  private fetchModels(): void {
    if (this.llmBase.trim().length === 0) {
      this.modelState = '';
      return;
    }
    const config = new LlmConfig();
    config.baseUrl = this.llmBase;
    config.token = this.llmToken;
    this.modelState = '连接中…';
    listModels(config).then((result: ModelList) => {
      if (!result.ok) {
        this.modelState = this.reason(result.problem);
        return;
      }
      const options: SelectOption[] = [];
      for (const id of result.models) {
        options.push({ value: id });
      }
      this.modelOptions = options;
      this.modelState = result.models.length + ' 个';
      if (this.llmModel.length === 0) {
        this.llmModel = result.models[0];
        this.modelIndex = 0;
        this.persistLlm();
      } else {
        const at = result.models.indexOf(this.llmModel);
        if (at >= 0) {
          this.modelIndex = at;
        }
      }
    });
  }

  private loadHarnessSettings(): void {
    loadLlmConfig().then((config: LlmConfig) => {
      this.llmBase = config.baseUrl;
      this.llmModel = config.model;
      this.llmToken = config.token;
      this.llmEffort = config.effort;
      if (config.baseUrl.length > 0) {
        this.fetchModels();
      }
    });
    loadExtraInstructions().then((text: string) => {
      this.extraPrompt = text;
    });
  }

  @Builder
  StatusRow(title: string, value: string) {
    Row({ space: 10 }) {
      Text(title).fontSize(15).fontColor(this.p().textPrimary)
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor(this.p().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.p().card)
    .borderRadius(12)
  }

  @Builder
  ImportSdkRow() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text('外部 SDK').fontSize(15).fontColor(this.p().textPrimary)
        Blank()
        Text(this.sdkState.length === 0 ? '读取中' : this.sdkState)
          .fontSize(13)
          .fontColor(this.p().textSecondary)
          .maxLines(2)
          .textAlign(TextAlign.End)
          .layoutWeight(2)
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('导入 SDK 压缩包')
          .fontSize(14)
          .fontColor(this.p().brand)
          .height(36)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .backgroundColor(this.p().brandSoft)
          .onClick(() => {
            this.sdkState = '解压并校验中…';
            importSdk().then((result: SdkImportResult) => {
              this.sdkState = result.message;
            }).catch((err: Error) => {
              this.sdkState = '导入失败：' + err.message;
            });
          })
      }
      .width('100%')

      Text('压缩包需含 oh-uni-package.json、openharmony/ets/api、hms/ets/api；校验通过才会替换，旧树留在 .hvolt/sdk.bundled')
        .fontSize(11)
        .fontColor(this.p().textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(this.p().card)
    .borderRadius(12)
  }

  @Builder
  OptionRow(title: string, labels: string[], key: string) {
    Column({ space: 8 }) {
      Text(title).fontSize(15).fontColor(this.p().textPrimary)
      Row({ space: 4 }) {
        ForEach(labels, (label: string, i: number) => {
          Text(label)
            .fontSize(13)
            .fontColor(i === this.selectedOf(key) ? this.p().brand : this.p().textSecondary)
            .fontWeight(i === this.selectedOf(key) ? FontWeight.Medium : FontWeight.Normal)
            .layoutWeight(1)
            .height(34)
            .textAlign(TextAlign.Center)
            .borderRadius(10)
            .backgroundColor(i === this.selectedOf(key) ? this.p().brandSoft : Color.Transparent)
            .onClick(() => {
              this.pick(key, i);
            })
        }, (label: string, i: number) => label + i)
      }
      .width('100%')
      .padding(3)
      .borderRadius(12)
      .backgroundColor(this.p().pane)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(14)
    .backgroundColor(this.p().card)
  }

  private fontLabels(): string[] {
    const out: string[] = [];
    for (const s of FONT_SIZES) {
      out.push('' + s);
    }
    return out;
  }

  /** 当前档位在四个选项里的下标；读不到就回默认档。 */
  private viewIndex(): number {
    const current = viewModeOf(AppStorage.get<string>(KEY_TRANSCRIPT_VIEW) ?? DEFAULT_TRANSCRIPT_VIEW);
    return TRANSCRIPT_VIEW_MODES.indexOf(current);
  }

  private collapseLabels(): string[] {
    const out: string[] = [];
    for (const timing of COLLAPSE_TIMINGS) {
      out.push(collapseTimingLabel(timing));
    }
    return out;
  }

  private viewLabels(): string[] {
    const out: string[] = [];
    for (const mode of TRANSCRIPT_VIEW_MODES) {
      out.push(viewModeLabel(mode));
    }
    return out;
  }

  private tabLabels(): string[] {
    const out: string[] = [];
    for (const s of TAB_SIZES) {
      out.push('' + s);
    }
    return out;
  }

  private tailLabels(): string[] {
    const out: string[] = [];
    for (const s of TAILS) {
      out.push('' + s);
    }
    return out;
  }

  private selectedOf(key: string): number {
    if (key === KEY_FONT) {
      return FONT_SIZES.indexOf(this.fontPx);
    }
    if (key === KEY_TAB) {
      return TAB_SIZES.indexOf(this.tabSize);
    }
    if (key === KEY_TAIL) {
      return TAILS.indexOf(this.logTail);
    }
    if (key === KEY_TRANSCRIPT_VIEW) {
      return TRANSCRIPT_VIEW_MODES.indexOf(viewModeOf(this.transcriptView));
    }
    if (key === KEY_COLLAPSE_TIMING) {
      return COLLAPSE_TIMINGS.indexOf(collapseTimingOf(this.collapseTiming));
    }
    return this.appearance;
  }

  private pick(key: string, i: number): void {
    hilog.info(0x0000, 'hvoltide', 'settings pick: %{public}s -> %{public}d', key, i);
    if (key === KEY_FONT) {
      this.setNumber(KEY_FONT, FONT_SIZES[i]);
      return;
    }
    if (key === KEY_TAB) {
      this.setNumber(KEY_TAB, TAB_SIZES[i]);
      return;
    }
    if (key === KEY_TAIL) {
      this.setNumber(KEY_TAIL, TAILS[i]);
      return;
    }
    if (key === KEY_TRANSCRIPT_VIEW) {
      this.transcriptView = TRANSCRIPT_VIEW_MODES[i];
      this.set(KEY_TRANSCRIPT_VIEW, this.transcriptView);
      return;
    }
    if (key === KEY_COLLAPSE_TIMING) {
      this.collapseTiming = COLLAPSE_TIMINGS[i];
      this.set(KEY_COLLAPSE_TIMING, this.collapseTiming);
      return;
    }
    this.appearance = i;
    AppStorage.setOrCreate('appearance', i);
    writePref('appearance', '' + i);
    this.onOptions();
  }

  /** One settings group, extracted from build() with its content unchanged. */
  @Builder
  EndpointSection() {
      Column({ space: 8 }) {
        Text('接口地址')
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .width('100%')
        TextInput({ text: $$this.llmBase, placeholder: 'https://api.deepseek.com/v1' })
          .height(40)
          .width('100%')
          .fontSize(14)
          .fontColor(this.p().textPrimary)
          .placeholderColor(this.p().textTertiary)
          .backgroundColor(this.p().bg)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange(() => {
            this.persistLlm();
          })
          .onBlur(() => {
            this.fetchModels();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .borderRadius(14)
      .backgroundColor(this.p().card)
  }

  /** One settings group, extracted from build() with its content unchanged. */
  @Builder
  ModelSection() {
      Column({ space: 8 }) {
        Row() {
          Text('模型')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
          Blank()
          Text(this.modelState)
            .fontSize(12)
            .fontColor(this.p().textTertiary)
        }
        .width('100%')

        Select(this.modelOptions.length > 0 ? this.modelOptions :
          [{ value: this.llmModel.length > 0 ? this.llmModel : '—' }])
          .selected(this.modelIndex)
          .value(this.llmModel.length > 0 ? this.llmModel : '—')
          .font({ size: 14 })
          .fontColor(this.p().textPrimary)
          .backgroundColor(this.p().bg)
          .borderRadius(10)
          .enabled(this.modelOptions.length > 0)
          .width('100%')
          .height(40)
          .onSelect((index: number, value: string) => {
            this.modelIndex = index;
            this.llmModel = value;
            this.persistLlm();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .borderRadius(14)
      .backgroundColor(this.p().card)
  }

  /** One settings group, extracted from build() with its content unchanged. */
  @Builder
  KeySection() {
      Column({ space: 8 }) {
        Text('密钥')
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .width('100%')
        TextInput({ text: $$this.llmToken, placeholder: 'API key' })
          .type(InputType.Password)
          .height(40)
          .width('100%')
          .fontSize(14)
          .fontColor(this.p().textPrimary)
          .placeholderColor(this.p().textTertiary)
          .backgroundColor(this.p().bg)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange(() => {
            this.persistLlm();
          })
          .onBlur(() => {
            this.fetchModels();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .borderRadius(14)
      .backgroundColor(this.p().card)
  }

  /** One settings group, extracted from build() with its content unchanged. */
  @Builder
  EffortSection() {
      Column({ space: 8 }) {
        Row() {
          Text('思考强度')
            .fontSize(15)
            .fontColor(this.p().textPrimary)
          Blank()
          Text('默认不传')
            .fontSize(12)
            .fontColor(this.p().textTertiary)
        }
        .width('100%')

        Row({ space: 8 }) {
          ForEach([['', '默认'], ['low', '低'], ['medium', '中'], ['high', '高']],
            (pair: string[]) => {
              Text(pair[1])
                .fontSize(13)
                .fontColor(this.llmEffort === pair[0] ? this.p().textPrimary : this.p().textSecondary)
                .height(34)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.llmEffort === pair[0] ? this.p().brandSoft : this.p().bg)
                .borderRadius(8)
                .onClick(() => {
                  this.llmEffort = pair[0];
                  this.persistLlm();
                })
            }, (pair: string[]) => pair[0] + pair[1])
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .borderRadius(14)
      .backgroundColor(this.p().card)
  }

  /** One settings group, extracted from build() with its content unchanged. */
  @Builder
  ExtraSection() {
      Column({ space: 8 }) {
        Text('附加指令')
          .fontSize(15)
          .fontColor(this.p().textPrimary)
          .width('100%')
        TextArea({ text: $$this.extraPrompt, placeholder: '例如：改完代码先跑 build 再回复我' })
          .width('100%')
          .height(88)
          .fontSize(14)
          .fontColor(this.p().textPrimary)
          .placeholderColor(this.p().textTertiary)
          .backgroundColor(this.p().bg)
          .borderRadius(10)
          .padding(12)
          .onChange(() => {
            saveExtraInstructions(this.extraPrompt);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .borderRadius(14)
      .backgroundColor(this.p().card)
  }


  build() {
    Column() {
      Row({ space: 8 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([this.p().textPrimary])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .onClick(() => {
          animateTo({ duration: DURATION, curve: spring() }, () => {
            this.onClose();
          });
        })
        Text('设置').fontSize(18).fontColor(this.p().textPrimary).fontWeight(FontWeight.Medium)
        Blank()
      }
      .width('100%')
      .height(56)
      .padding({ left: GAP, right: GAP })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 8 }) {
          this.Section('模型接入')
          this.EndpointSection()

          this.ModelSection()

          this.KeySection()

          this.EffortSection()


          this.ExtraSection()

          this.Section('SDK')
          this.StatusRow('内置 SDK 目录', this.sdkDiskState())
          // Importing is the only way to reach a HMS component: the bundled tree has no `hms/`.
          // The row reports what is actually on disk, not what was last attempted.
          this.ImportSdkRow()

          this.Section('编辑器')
          this.OptionRow('字号', this.fontLabels(), KEY_FONT)
          SwitchRow({
            dark: this.dark,
            title: '行号',
            hint: '编辑区左侧行号列',
            value: this.lineNumbers,
            onFlip: (on: boolean) => {
              this.set(KEY_LINES, on ? '1' : '0');
            }
          })
          SwitchRow({
            dark: this.dark,
            title: '切标签时保存',
            hint: '离开前把缓冲区写回磁盘',
            value: AppStorage.get<string>(KEY_SAVE_ON_SWITCH) === '1',
            onFlip: (on: boolean) => {
              this.set(KEY_SAVE_ON_SWITCH, on ? '1' : '0');
            }
          })
          SwitchRow({
            dark: this.dark,
            title: '自动换行',
            hint: '长行按宽度折行',
            value: this.wordWrap,
            onFlip: (on: boolean) => {
              this.set(KEY_WRAP, on ? '1' : '0');
            }
          })
          this.OptionRow('缩进宽度', this.tabLabels(), KEY_TAB)
          SwitchRow({
            dark: this.dark,
            title: '自动保存',
            hint: '切换文件前写回当前缓冲区',
            value: this.autoSave,
            onFlip: (on: boolean) => {
              this.set(KEY_AUTOSAVE, on ? '1' : '0');
            }
          })

          this.Section('对话')
          this.OptionRow('工作步骤展示', this.viewLabels(), KEY_TRANSCRIPT_VIEW)
          this.OptionRow('完成时折叠', this.collapseLabels(), KEY_COLLAPSE_TIMING)

          this.Section('构建')
          SwitchRow({
            dark: this.dark,
            title: '构建后自动部署',
            hint: '构建完成后自动安装并启动',
            value: this.autoDeploy,
            onFlip: (on: boolean) => {
              this.set('autodeploy', on ? '1' : '0');
            }
          })
          SwitchRow({
            dark: this.dark,
            title: '代码混淆',
            hint: readObfuscation(this.project) ? '当前工程已开启' : '当前工程未开启',
            value: this.obfuscate,
            onFlip: (on: boolean) => {
              this.set(KEY_OBFUSCATE, on ? '1' : '0');
              setObfuscation(this.project, on);
            }
          })

          this.Section('设备与日志')
          // Host and port are separate fields: a device is added as an address, and the
          // saved ones stay reachable after the sheet closes.
          Row({ space: 8 }) {
            TextInput({ text: this.devIp, placeholder: 'IP' })
              .height(36)
              .layoutWeight(3)
              .fontSize(13)
              .fontColor(this.p().textPrimary)
              .placeholderColor(this.p().textTertiary)
              .backgroundColor(this.p().pane)
              .borderRadius(10)
              .padding({ left: 10, right: 10 })
              .onChange((v: string) => {
                this.devIp = v;
              })
            TextInput({ text: this.devPort, placeholder: '端口' })
              .height(36)
              .layoutWeight(2)
              .type(InputType.Number)
              .fontSize(13)
              .fontColor(this.p().textPrimary)
              .placeholderColor(this.p().textTertiary)
              .backgroundColor(this.p().pane)
              .borderRadius(10)
              .padding({ left: 10, right: 10 })
              .onChange((v: string) => {
                this.devPort = v;
              })
            Text('添加')
              .fontSize(13)
              .fontColor(this.p().textPrimary)
              .height(36)
              .padding({ left: 12, right: 12 })
              .borderRadius(10)
              .backgroundColor(this.p().pane)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.addDevice();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)
          .borderRadius(14)
          .backgroundColor(this.p().card)

          if (this.devices.length > 0) {
            Column() {
              ForEach(this.devices, (addr: string, i: number) => {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(addr)
                      .fontSize(14)
                      .fontColor(this.p().textPrimary)
                      .maxLines(1)
                    // The row reads the session's own target, not a local copy: a local
                  // copy only refreshes when the row is tapped.
                  Text(addr === this.device
                    ? (this.link === 2 ? '已连接 · 当前安装目标' : '当前安装目标')
                    : (addr === this.curTarget && this.link === 2 ? '已连接' : '未连接'))
                    .fontSize(11)
                    .fontColor((addr === this.device || addr === this.curTarget) && this.link === 2
                      ? this.p().ok
                      : this.p().textTertiary)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .onClick(() => {
                    this.connectTo(addr);
                  })
                  Text('✕')
                    .fontSize(13)
                    .fontColor(this.p().textTertiary)
                    .width(30)
                    .height(30)
                    .textAlign(TextAlign.Center)
                    .onClick(() => {
                      this.removeDevice(addr);
                    })
                }
                .width('100%')
                .height(52)
                .padding({ left: 16, right: 8 })
                .alignItems(VerticalAlign.Center)
                .border({ width: { bottom: 0.5 }, color: this.p().line })
              }, (addr: string) => addr)
            }
            .width('100%')
            .borderRadius(14)
            .backgroundColor(this.p().card)
            .clip(true)
          }

          if (this.devFeedback.length > 0) {
            Text(this.devFeedback)
              .fontSize(11)
              .fontColor(this.p().textSecondary)
              .width('100%')
              .padding({ left: 6, right: 6 })
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          SwitchRow({
            dark: this.dark,
            title: '启动时自动连接',
            hint: '打开应用即注册本机安装目标',
            value: this.autoConnect,
            onFlip: (on: boolean) => {
              this.set(KEY_AUTOCONNECT, on ? '1' : '0');
            }
          })
          this.OptionRow('日志行数', this.tailLabels(), KEY_TAIL)

          this.Section('外观')
          this.OptionRow('主题', ['跟随系统', '深色', '浅色'], 'appearance')

          this.Section('AGC 与部署')
          Row() {
            Column({ space: 2 }) {
              Text('AppGallery Connect').fontSize(15).fontColor(this.p().textPrimary)
              Text(this.agcUser.length > 0 ? 'User ID ' + this.agcUser : this.agcState)
                .fontSize(12)
                .fontColor(this.p().textSecondary)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(this.agcUser.length === 0 ? '登录' : '登出')
              .fontSize(13)
              .fontColor(this.p().brand)
              .height(34)
              .padding({ left: 14, right: 14 })
              .borderRadius(10)
              .backgroundColor(this.p().brandSoft)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (this.agcUser.length === 0) {
                  this.onAgcLogin();
                } else {
                  this.onAgcLogout();
                }
              })

          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .borderRadius(14)
          .backgroundColor(this.p().card)

          if (this.traceTail.length > 0) {
            Text(this.traceTail)
              .fontSize(10)
              .fontColor(this.p().textTertiary)
              .width('100%')
              .padding({ left: 4, top: 8 })
              .maxLines(8)
          }

          Text(this.aboutInfo)
            .fontSize(11)
            .fontColor(this.p().textTertiary)
            .width('100%')
            .padding({ left: 4, top: 16, bottom: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.p().bg)
    .transition(TransitionEffect.OPACITY)
  }


}

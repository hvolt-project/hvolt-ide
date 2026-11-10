// Everything the shell can *do*, kept out of the page so the entry file only holds the
// layout and the transient UI switches. `onChange` is the single channel back to the
// page: the page mirrors these fields into @State and re-renders on the call.
import web_webview from '@ohos.web.webview';

import { Bp, EditorBridge, setEditorHandlers, setPendingText } from './Bridge';
import { withLine } from './Util';
import { FILES, PROJ, listSources, stageProject } from './Stage';
import { SELF_HDC, hvolt, hvoltArgv, HvoltResult } from './Hvolt';
import {
  ActionResult, agcLogin, connectDevice, readLogs, runBuild, runDeploy, runInstall, runStart, whoami
} from './Actions';
import { flushEditor, pushText } from './Editor';
import {
  createProject, createTreeFile, deleteProject as deleteProjectFromDisk, deleteTreeEntry, exists, fileSize,
  isBinaryFile, isImageFile, pickFilesInto,
  listProjects, pickFolderAndImport, projectBundle, projectDir, projectSourceCount, readSource,
  writeSource
} from './Project';
import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { startHarness } from '../harness/Harness';
import { ChatSession } from '../harness/loop/Loop';
import { Usage } from '../harness/loop/Types';
import { LlmConfig, loadLlmConfig } from '../harness/loop/Settings';
import { buildSystemPrompt, runtimeBlock } from '../harness/Prompt';
import { ProjectWatcher, WatchEvent } from '../harness/fs/Watch';
import hilog from '@ohos.hilog';
import { readPref, writePref } from './Prefs';
import { connectAsync, hvoltAsync, streamNextAsync } from './Connect';
import { streamRead, streamStop } from 'libnavi.so';
import { streamStartAsync } from './Connect';
import {
  KEY_AUTOCONNECT, KEY_AUTOSAVE, KEY_FONT, KEY_SAVE_ON_SWITCH, KEY_TAIL, ShellOptions, applyEditorOptions,
  loadOptions
} from './Options';

const OWN_BUNDLE: string = 'xyz.sudofree.hvolt.ide';

// Shapes of the follower's replies; the ring lives in libhvolt, this side only keeps a
// cursor into it.
interface StreamOpen {
  code: number;
  handle: number;
  output?: string;
}

interface AgcAuthInfo {
  port: number;
  url: string;
}

interface StreamPage {
  next: number;
  rows: string[];
}

// The captured stdout also carries the WebView's own logging, so a failure message has to
// be picked out rather than read off the first line.
function firstLine(text: string): string {
  const lines = text.trim().split('\n');
  for (const line of lines) {
    if (line.indexOf('✗') >= 0) {
      return line.trim();
    }
  }
  return lines.length > 0 ? lines[0].trim() : '';
}


/** One line at the end of a turn: what it cost and how long it took. */
function statLine(usage: Usage, rounds: number, millis: number): string {
  const parts: string[] = [];
  parts.push((millis / 1000).toFixed(1) + 's');
  if (usage.totalTokens > 0) {
    parts.push('in ' + usage.promptTokens + ' · out ' + usage.completionTokens);
    if (usage.reasoningTokens > 0) {
      parts.push('思考 ' + usage.reasoningTokens);
    }
  }
  if (rounds > 1) {
    parts.push(rounds + ' 轮');
  }
  return parts.join(' · ');
}

export class Session {
  readonly controller: web_webview.WebviewController = new web_webview.WebviewController();
  readonly bridge: EditorBridge = new EditorBridge();

  files: string[] = [];
  // Open tabs in the order they were opened; `current` is the active one.
  openTabs: string[] = [];
  dirtyTabs: string[] = [];
  curLine: number = 0;
  curCol: number = 0;
  chromeHidden: boolean = false;
  // Read at boot, consumed by the first openProject: the tabs of the last session only
  // make sense once the same project is back on screen.
  private pendingTabs: string[] = [];
  private pendingCurrent: string = '';
  current: string = '';
  projects: string[] = [];
  project: string = '';
  sourceCount: number = 0;
  log: string = '';
  statusText: string = '就绪';
  statusTone: number = 0;
  busy: boolean = false;
  // hilog filters; empty means "no filter on this axis".
  logLevel: string = '';
  logTag: string = '';
  logKeywords: string[] = [];
  agcUrl: string = '';
  // Set once whoami answers; the sheet shows the account instead of a login button.
  agcUser: string = '';
  hlog: string = '';
  // 0 not connected, 1 connecting, 2 connected, 3 failed. The status bar's dot and the
  // device list both read this one value, so they can never disagree.
  link: number = 0;
  linkState: string = '未连接';
  // Outline comes from the built .abc, not from parsing source: the record table is what the
  // runtime addresses, and hvolt already reads it without ark_disasm.
  outline: string[] = [];
  outlineNote: string = '先构建';
  agcState: string = '';
  signingReady: boolean = false;
  version: string = '';
  device: string = SELF_HDC;
  // Addresses the user added by hand; the built-in loopback target is always present.
  devices: string[] = [];
  ready: boolean = false;

  // The page owns these switches because they drive layout, but the session needs to
  // read them while it loads files and chrome.
  dark: boolean = true;
  rightOpen: boolean = false;
  onChange: () => void = () => {
  };

  private staged: boolean = false;
  private options: ShellOptions = new ShellOptions();

  /** Absolute sandbox path of the open project, for the harness tools. */
  projectPath(): string {
    return this.dir();
  }

  private watcher: ProjectWatcher = new ProjectWatcher();

  /** One conversation per app session; I11 persists it across restarts. */
  chat: ChatSession = new ChatSession();

  private chatFile(name: string): string {
    return this.filesDir() + '/projects/' + name + '/.hvolt/chat.jsonl';
  }

  private filesDir(): string {
    return getContext().filesDir;
  }

  /**
   * Restores the project's conversation from its jsonl file, one message per line.
   *
   * Compression is deliberately not part of this path: `zlib.compressFile` returned success
   * without producing a file on this device, and a history that only loads when a compressor
   * cooperates is worse than an uncompressed one that always loads.
   */
  private loadChat(name: string): void {
    const path = this.chatFile(name);
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const text = fs.readTextSync(path);
      this.chat.load(text);
      const messages = this.chat.messages().length;
      hilog.info(0x0000, 'hvoltide', 'chat restored: %{public}d messages', messages);
    } catch (e) {
      this.append('chat history load failed: ' + (e as Error).message);
    }
  }

  private saveChat(): void {
    if (this.project.length === 0) {
      return;
    }
    const path = this.chatFile(this.project);
    try {
      const dir = path.substring(0, path.lastIndexOf('/'));
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const text = this.chat.dump();
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      hilog.info(0x0000, 'hvoltide', 'chat saved: %{public}d bytes', text.length);
    } catch (e) {
      this.append('chat history save failed: ' + (e as Error).message);
    }
  }

  /** Runs one chat turn, reporting each event to the caller for rendering. */
  async chatSend(userText: string,
    onEvent: (kind: string, text: string) => void): Promise<void> {
    const config: LlmConfig = await loadLlmConfig();
    if (!config.ready()) {
      onEvent('error', '先在设置里填模型地址、模型名与密钥');
      return;
    }
    const prompt = await buildSystemPrompt();
    this.chat.setSystem(prompt);
    // State travels with the message, not in the system prompt: that keeps the cacheable
    // prefix identical from turn to turn.
    const state = runtimeBlock({
      projectName: this.project,
      currentFile: this.current,
      deviceAddress: this.device,
      connected: this.link === 2
    });
    await this.chat.send(config, state + '\n\n' + userText, {
      onText: (delta: string) => {
        onEvent('text', delta);
      },
      onThought: (delta: string) => {
        onEvent('thought', delta);
      },
      onToolStart: (call) => {
        onEvent('tool', call.name + ' ' + call.argumentsJson);
      },
      onToolResult: (id: string, text: string) => {
        onEvent('result', text);
      },
      onError: (message: string) => {
        onEvent('error', message);
      },
      onStats: (usage, rounds: number, millis: number) => {
        onEvent('stats', statLine(usage, rounds, millis));
      },
      onDone: () => {
        onEvent('done', '');
      }
    });
    this.saveChat();
  }

  chatStop(): void {
    this.chat.stop();
  }

  chatReset(): void {
    this.chat.reset();
  }

  private dir(): string {
    return this.project.length === 0 ? PROJ : projectDir(this.project);
  }

  projectPath(): string {
    return this.dir();
  }

  bundleId(): string {
    return projectBundle(this.project, OWN_BUNDLE);
  }

  // One boot: read the persisted environment, ask the toolchain what it is, register the
  // loopback channel as the install target, then unpack the samples.
  start(onReady: () => void): void {
    setEditorHandlers((initial: string) => {
      this.ready = true;
      onReady();
      this.publishFirstFile();

      this.syncChrome();
      this.applyOptions();
    }, (text: string) => {
      this.saveCurrent(text);
    }, (rel: string, flag: boolean) => {
      this.markDirty(rel, flag);
    }, (line: number, col: number) => {
      this.curLine = line;
      this.curCol = col;
      this.onChange();
    }, (hidden: boolean) => {
      if (this.chromeHidden !== hidden) {
        this.chromeHidden = hidden;
        this.onChange();
      }
    });
    this.boot();
  }

  // The trace file is the only record a call leaves when it takes the process down;
  // put its tail where it can be read without opening anything.
  private showTraceTail(): void {
    try {
      const path = FILES + '/hvolt-trace.log';
      if (!fs.accessSync(path)) {
        hilog.info(0x0000, 'hvoltide', 'TRACE absent %{public}s', path);
        return;
      }
      const text = fs.readTextSync(path);
      const lines = text.trim().split('\n');
      // Also onto the device log: the trace lives in the sandbox, which the host cannot read.
      hilog.info(0x0000, 'hvoltide', 'TRACE %{public}s', lines.slice(Math.max(0, lines.length - 8)).join(' || '));
      this.statusText = 'trace: ' + lines.slice(Math.max(0, lines.length - 3)).join(' | ');
      this.onChange();
    } catch (e) {
    }
  }

  // The switch in settings; the call goes to a worker so a device that is slow to answer
  // cannot stall the workbench.
  private autoConnectOnBoot(): void {
    const on = AppStorage.get<string>(KEY_AUTOCONNECT) ?? '1';
    if (on !== '1' || this.device.length === 0) {
      return;
    }
    this.setLink(1, '连接中');
    connectAsync(this.device, FILES, (raw: string) => {
      const r: HvoltResult = JSON.parse(raw) as HvoltResult;
      if (r.code === 0) {
        this.setLink(2, '');
      } else {
        this.setLink(3, firstLine(r.output));
      }
    });
  }

  private async boot(): Promise<void> {
    this.options = await loadOptions();
    this.device = await readPref('device', SELF_HDC);
    const savedDevices = await readPref('devices', '[]');
    try {
      this.devices = JSON.parse(savedDevices) as string[];
    } catch (e) {
      this.devices = [];
    }
    AppStorage.setOrCreate('ide.devices', this.devices);
    AppStorage.setOrCreate('appearance', Number(await readPref('appearance', '0')));
    AppStorage.setOrCreate('autodeploy', await readPref('autodeploy', '0'));
    const v = hvolt(hvoltArgv(['--version']), FILES, FILES);
    this.version = v.code === 0 ? v.output.trim() : 'hvolt 不可用';
    this.pendingTabs = JSON.parse(await readPref('session.tabs', '[]')) as string[];
    this.pendingCurrent = await readPref('session.current', '');
    this.signingReady = exists(FILES + '/.harmony');
    // Boot does not wait on AGC: the query reaches the network when a backend exists, and
    // the status line only needs a starting value. The sheet refreshes it on open.
    // The token lives in the sandbox and survives a restart, so the account is read back
    // on boot instead of waiting for the user to press log in again.
    this.agcState = '查询中';
    // Connecting is not a boot step: the handshake against a device that is not up yet blocks
    // for as long as the transport waits, and the workbench has nothing to show meanwhile.
    // The channel connects when the user asks for it (settings, or the first device action).
    this.link = 0;
    this.linkState = '未连接';
    this.showTraceTail();
    this.autoConnectOnBoot();
    this.queryAgc();
    this.onChange();
    this.stageAll();
    // The endpoint is a side facility: a bind failure leaves a working editor and one log line.
    startHarness({
      projectDir: () => {
        return this.projectPath();
      },
      // The endpoint talks to the same session the page shows: one conversation, one history.
      chatSend: async (text: string): Promise<string> => {
        let reply = '';
        await this.chatSend(text, (kind: string, body: string) => {
          if (kind === 'text') {
            reply += body;
          }
        });
        return reply;
      }
    });
  }

  // Called once the page has finished loading. No script is issued from here: a
  // `runJavaScript` inside a webview lifecycle callback crashes the renderer on this device,
  // which is what took the process down. The text is published for the page to pull instead.
  publishFirstFile(): void {
    if (this.files.length === 0 || this.current.length > 0) {
      return;
    }
    const rel = this.files[0];
    this.current = rel;
    this.addTab(rel);
    try {
      const text = readSource(this.project, rel);
      setPendingText(text);
      this.append('open ' + rel + ' (' + text.length + ' chars)');
    } catch (e) {
      this.append('open failed: ' + rel);
    }
  }

  private append(line: string): void {
    // Mirrored to the device log: the panel is only visible while the app is in front, and
    // a build that takes the process down leaves nothing behind in the UI.
    // hilog cuts a message at a fixed length, so a long toolchain output arrives truncated.
    // Chopping it here keeps every line of the build log readable from outside the app.
    const CHUNK: number = 800;
    for (let at = 0; at < line.length; at += CHUNK) {
      hilog.info(0x0000, 'hvoltide', 'LOG %{public}s', line.substring(at, at + CHUNK));
    }
    this.log = withLine(this.log, line);
    this.onChange();
  }

  stageAll(): void {
    if (this.staged) {
      return;
    }
    this.staged = true;
    stageProject(() => {
      this.append('staged ' + FILES + '/stage · signing=' + this.signingReady);
      this.refreshProjects();
    }, (msg: string) => {
      this.append('stage failed: ' + msg);
    });
  }

  // Re-reads the source list for the open project: the tree otherwise keeps whatever it
  // saw when the project was opened.
  // Closing is not deleting: the project stays on disk, the workspace just lets go of it.
  // With save-on-switch on, at most the visible tab can be unsaved, so this is the only
  // buffer worth writing before the project goes away.
  hasDirtyCurrent(): boolean {
    return this.current.length > 0 && this.isDirtyTab(this.current);
  }

  closeProjectSaving(): void {
    flushEditor(this.controller, this.project, this.current, (line: string) => {
      this.append(line);
    }, (written: boolean) => {
      if (!written) {
        this.append('close: save failed for ' + this.current);
      }
      this.closeProject();
    });
  }

  closeProject(): void {
    if (this.project.length === 0) {
      return;
    }
    const gone = this.project;
    // Kept per project: reopening the same project should come back to the same tabs, and a
    // different project should not inherit them.
    writePref('tabs.' + gone, JSON.stringify(this.openTabs));
    this.project = '';
    this.current = '';
    this.files = [];
    this.openTabs = [];
    this.dirtyTabs = [];
    this.sourceCount = 0;
    writePref('project', '');
    writePref('session.tabs', '[]');
    writePref('session.current', '');
    setPendingText('');
    if (this.ready) {
      pushText(this.controller, '', '', (line: string) => {
        this.append('editor:' + line);
      });
    }
    this.ready = false;
    this.append('close project ' + gone);
    this.onChange();
  }

  // Deleting the open project closes it first: the file list, tabs and editor buffer all
  // point at paths that are about to disappear.
  deleteProject(name: string): void {
    if (name === this.project) {
      this.closeProject();
    }
    const ok = deleteProjectFromDisk(name);
    this.projects = listProjects();
    if (!ok) {
      this.append('delete failed: ' + name);
    } else {
      this.append('deleted project ' + name);
      if (this.projects.length === 0) {
        this.statusText = '没有工程';
      }
    }
    this.onChange();
  }

  rescan(): void {
    if (this.project.length === 0) {
      return;
    }
    const out: string[] = [];
    listSources(this.dir(), '', out);
    this.files = out;
    this.sourceCount = projectSourceCount(this.project);
    if (this.current.length > 0 && out.indexOf(this.current) < 0) {
      this.current = out.length > 0 ? out[0] : '';
    }
    this.append('rescan ' + this.project + ' · ' + out.length + ' 源文件');
    this.persistSession();
    this.onChange();
  }

  // Tree edits land on disk and then rescan, so the tree never shows a file that is gone or
  // misses one that appeared. Deleting the open file moves the selection like rescan does.
  deleteTreeFile(rel: string): void {
    if (this.project.length === 0) {
      return;
    }
    const ok = deleteTreeEntry(this.project, rel);
    this.append((ok ? 'deleted ' : 'delete failed ') + rel);
    if (ok) {
      this.closeTab(rel);
    }
    this.rescan();
  }

  createFileIn(dirRel: string, fileName: string): void {
    if (this.project.length === 0) {
      return;
    }
    const ok = createTreeFile(this.project, dirRel, fileName);
    this.append((ok ? 'created ' : 'create failed ') + (dirRel.length === 0 ? '' : dirRel + '/') + fileName);
    this.rescan();
    if (ok) {
      this.openFile(dirRel.length === 0 ? fileName : dirRel + '/' + fileName);
    }
  }

  importFilesInto(dirRel: string): void {
    if (this.project.length === 0) {
      return;
    }
    pickFilesInto(this.project, dirRel).then((line: string) => {
      this.append('import ' + (dirRel.length === 0 ? '/' : dirRel) + ': ' + line);
      this.rescan();
    });
  }

  refreshProjects(): void {
    this.projects = listProjects();
    if (this.projects.length === 0) {
      this.project = '';
      this.statusText = '没有工程';
      this.onChange();
      return;
    }
    // Only what the user left open comes back. Falling back to the first project would
    // reopen something they explicitly closed.
    readPref('project', '').then((saved: string) => {
      if (saved.length > 0 && this.projects.indexOf(saved) >= 0) {
        this.openProject(saved);
        return;
      }
      this.project = '';
      this.current = '';
      this.files = [];
      this.openTabs = [];
      this.statusText = '未打开工程';
      this.onChange();
    });
  }

  /** Re-reads the tree and reopens the current file when someone else changed it. */
  private onTreeChanged(events: WatchEvent[]): void {
    const live: string[] = [];
    listSources(this.dir(), '', live);
    this.files = live;
    this.sourceCount = live.length;
    let touchedCurrent = false;
    for (const event of events) {
      if (event.removed) {
        touchedCurrent = true;
      }
      if (this.current.length > 0 && event.path.endsWith('/' + this.current)) {
        touchedCurrent = true;
      }
    }
    if (touchedCurrent) {
      this.append('工程文件已变化 · ' + events.length + ' 处');
      this.onChange();
    }
  }

  stopWatching(): void {
    this.watcher.stop();
  }

  openProject(name: string): void {
    this.project = name;
    writePref('project', name);
    this.current = '';
    this.sourceCount = projectSourceCount(name);
    const out: string[] = [];
    listSources(this.dir(), '', out);
    this.files = out;
    this.statusText = '工程 ' + name;
    this.statusTone = 0;
    this.append('open project ' + name + ' · ' + this.sourceCount + ' 源文件');
    // Outside writers (the assistant, a build) change the tree behind the editor's back.
    this.watcher.start(this.dir(), (events: WatchEvent[]) => {
      this.onTreeChanged(events);
    });
    this.loadChat(name);
    readPref('tabs.' + name, '[]').then((raw: string) => {
      if (this.project !== name) {
        return;
      }
      let saved: string[] = [];
      try {
        const parsed = JSON.parse(raw) as string[];
        saved = parsed as string[];
      } catch (e) {
        saved = [];
      }
      const live: string[] = [];
      for (const rel of saved) {
        if (this.files.indexOf(rel) >= 0 && live.indexOf(rel) < 0) {
          live.push(rel);
        }
      }
      if (live.length > 0) {
        this.openTabs = live;
        if (live.indexOf(this.current) < 0) {
          this.current = live[0];
          try {
            setPendingText(readSource(this.project, this.current));
          } catch (e) {
            this.append('restore failed: ' + this.current);
          }
        }
        this.append('tabs ' + this.project + ': ' + live.length);
        this.onChange();
      }
    });
    if (out.length > 0) {
      this.current = out[0];
      this.addTab(this.current);
      try {
        setPendingText(readSource(name, out[0]));
      } catch (e) {
        setPendingText('');
      }
    }
    if (this.pendingTabs.length > 0) {
      const kept: string[] = [];
      for (let i = 0; i < this.pendingTabs.length; i++) {
        if (out.indexOf(this.pendingTabs[i]) >= 0) {
          kept.push(this.pendingTabs[i]);
        }
      }
      if (kept.length > 0) {
        this.openTabs = kept;
        if (this.pendingCurrent.length > 0 && kept.indexOf(this.pendingCurrent) >= 0) {
          this.current = this.pendingCurrent;
          try {
            setPendingText(readSource(name, this.current));
          } catch (e) {
            this.append('restore failed: ' + this.current);
          }
        }
      }
      this.pendingTabs = [];
      this.pendingCurrent = '';
      this.append('restored ' + this.openTabs.length + ' 个标签');
    }
    this.persistSession();
    // Monaco is not listening during first launch; the ready callback opens the file.
    if (this.ready && this.files.length > 0) {
      this.openFile(this.current.length > 0 ? this.current : this.files[0]);
    }
  }

  private addTab(rel: string): void {
    if (rel.length === 0 || this.openTabs.indexOf(rel) >= 0) {
      return;
    }
    this.openTabs.push(rel);
  }

  // Switching away is the last moment the buffer of the old file exists, so when the option
  // is on the write happens first and the switch waits for it.
  openFile(rel: string): void {
    const leaving = this.current;
    const shouldSave = this.current.length > 0 && this.current !== rel &&
      (this.options.saveOnSwitch || this.options.autoSave);
    if (!shouldSave || !this.ready) {
      this.openFileNow(rel);
      return;
    }
    flushEditor(this.controller, this.project, leaving, (line: string) => {
      this.append(line);
    }, (written: boolean) => {
      if (written) {
        this.markDirty(leaving, false);
      } else {
        // A failed write keeps the dirty mark: the file on disk no longer matches the buffer.
        this.append('save on switch failed: ' + leaving);
      }
      // Same reason as flushThen: the switch pushes text back into the WebView.
      setTimeout(() => {
        this.openFileNow(rel);
      }, 0);
    });
  }

  private openFileNow(rel: string): void {
    this.current = rel;
    this.loadOutline();
    this.addTab(rel);
    // A binary never reaches the text editor: no read, no push, nothing that could be
    // written back over the bytes.
    if (!isImageFile(this.dir(), rel) && isBinaryFile(this.dir(), rel)) {
      this.append('open ' + rel + ' (' + fileSize(this.project, rel) + ' bytes, binary)');
      if (this.ready) {
        pushText(this.controller, '', rel, (line: string) => {
          this.append('editor:' + line);
        });
      } else {
        setPendingText('');
      }
      this.persistSession();
      this.onChange();
      return;
    }
    // An image never reaches the text editor either.
    if (isImageFile(this.dir(), rel)) {
      this.append('open ' + rel + ' (' + fileSize(this.project, rel) + ' bytes, preview)');
      if (this.ready) {
        pushText(this.controller, '', rel, (line: string) => {
          this.append('editor:' + line);
        });
      } else {
        setPendingText('');
      }
      this.persistSession();
      this.onChange();
      return;
    }
    let text = '';
    try {
      text = readSource(this.project, rel);
      this.append('open ' + rel + ' (' + text.length + ' chars)');
    } catch (e) {
      this.append('open failed: ' + rel);
    }
    // Pushing matters: the page already holds the previous file, so a switch is a rewrite,
    // not a pull.
    if (this.ready) {
      pushText(this.controller, text, rel, (line: string) => {
        this.append('editor:' + line);
      });
    } else {
      setPendingText(text);
    }
    this.persistSession();
    this.onChange();
  }

  // The workspace reopens to the tabs it was left with; the list is small enough to keep
  // as one preference string.
  private persistSession(): void {
    writePref('session.tabs', JSON.stringify(this.openTabs));
    writePref('session.current', this.current);
  }

  // Closing the active tab hands the editor to its neighbour; closing the last one clears
  // the buffer instead of leaving stale text on screen.
  isDirtyTab(rel: string): boolean {
    return this.dirtyTabs.indexOf(rel) >= 0;
  }

  // Nothing is written: the caller has already asked, and this is the answer they chose.
  discardTab(rel: string): void {
    this.markDirty(rel, false);
    this.closeTab(rel);
  }

  // Pulls the buffer out of the editor first, because closing the tab destroys it.
  closeTabSaving(rel: string): void {
    flushEditor(this.controller, this.project, rel, (line: string) => {
      this.append(line);
    }, (written: boolean) => {
      if (written) {
        this.markDirty(rel, false);
        setTimeout(() => {
          this.closeTab(rel);
        }, 0);
      } else {
        this.statusText = '保存失败';
        this.statusTone = 3;
        this.onChange();
      }
    });
  }

  closeTab(rel: string): void {
    const at = this.openTabs.indexOf(rel);
    if (at < 0) {
      return;
    }
    this.openTabs.splice(at, 1);
    const d = this.dirtyTabs.indexOf(rel);
    if (d >= 0) {
      this.dirtyTabs.splice(d, 1);
    }
    if (this.current !== rel) {
      this.onChange();
      return;
    }
    const next = this.openTabs.length === 0 ? ''
      : this.openTabs[Math.min(at, this.openTabs.length - 1)];
    if (next.length === 0) {
      this.current = '';
      if (this.ready) {
        pushText(this.controller, '', '', (line: string) => {
          this.append('editor:' + line);
        });
      } else {
        setPendingText('');
      }
      this.append('close ' + rel + ' · no tab left');
      this.persistSession();
      this.onChange();
      return;
    }
    this.openFile(next);
  }

  markDirty(rel: string, flag: boolean): void {
    if (rel.length === 0) {
      return;
    }
    const at = this.dirtyTabs.indexOf(rel);
    if (flag && at < 0) {
      this.dirtyTabs.push(rel);
    } else if (!flag && at >= 0) {
      this.dirtyTabs.splice(at, 1);
    }
    this.onChange();
  }

  saveCurrent(text: string): void {
    if (this.current.length === 0 || isImageFile(this.dir(), this.current)) {
      return;
    }
    const ok = writeSource(this.project, this.current, text);
    if (ok) {
      const at = this.dirtyTabs.indexOf(this.current);
      if (at >= 0) {
        this.dirtyTabs.splice(at, 1);
      }
    }
    this.append(ok ? 'saved ' + this.current + ' (' + text.length + ' chars)'
      : 'save failed: ' + this.current);
  }

  // The buffer write is asynchronous; every step that reads the files from disk has to wait
  // for it, or it compiles the previous contents.
  private flushThen(next: () => void): void {
    if (!this.ready || this.current.length === 0 || isImageFile(this.dir(), this.current) ||
      isBinaryFile(this.dir(), this.current)) {
      next();
      return;
    }
    const rel = this.current;
    flushEditor(this.controller, this.project, rel, (line: string) => {
      this.append(line);
    }, (written: boolean) => {
      if (!written) {
        this.append('flush failed before task: ' + rel);
      }
      // Outside the runJavaScript callback: calling the toolchain NAPI from inside it aborts
      // the process on this device, the same trap the lifecycle hook documents above.
      setTimeout(() => {
        next();
      }, 0);
    });
  }

  flush(): void {
    // Nothing to flush for a preview: the page holds no text of this file.
    if (!this.ready || this.current.length === 0 || isImageFile(this.dir(), this.current)) {
      return;
    }
    flushEditor(this.controller, this.project, this.current, (line: string) => {
      this.append(line);
    });
  }

  // Editor options are read back from AppStorage on every change, so the sheet only has
  // to publish the new value.
  applyOptions(): void {
    // Options are stored even with no editor on screen; only the push needs one.
    if (!this.ready) {
      return;
    }
    const o = new ShellOptions();
    o.fontSize = AppStorage.get<number>(KEY_FONT) ?? 14;
    o.lineNumbers = AppStorage.get<string>('opt.lineNumbers') === '1';
    o.wordWrap = AppStorage.get<string>('opt.wordWrap') === '1';
    o.tabSize = AppStorage.get<number>('opt.tabSize') ?? 2;
    o.autoSave = AppStorage.get<string>(KEY_AUTOSAVE) === '1';
    o.saveOnSwitch = AppStorage.get<string>(KEY_SAVE_ON_SWITCH) === '1';
    o.logTail = AppStorage.get<number>(KEY_TAIL) ?? 120;
    this.options = o;
    applyEditorOptions(this.controller, o, (line: string) => {
      this.append(line);
    });
  }

  // Monaco owns the minimap and the palette; the shell only reports what changed.
  syncChrome(): void {
    if (!this.ready) {
      return;
    }
    this.controller.runJavaScript('hvoltSetTheme(' + (this.dark ? 'true' : 'false') + ')')
      .catch((e: Error) => {
        this.append('theme: ' + e.message);
      });
    this.controller.runJavaScript('hvoltSetMinimap(' + (this.rightOpen ? 'false' : 'true') + ')')
      .catch((e: Error) => {
        this.append('minimap: ' + e.message);
      });
  }

  clearEditor(): void {
    if (!this.ready) {
      return;
    }
    this.controller.runJavaScript('hvoltSetText("", "arkts")').catch((e: Error) => {
      this.append('editor: ' + e.message);
    });
  }

  createProjectNamed(name: string): void {
    createProject(name).then((err: string) => {
      if (err.length > 0) {
        this.append('新建工程失败：' + err);
        return;
      }
      this.projects = listProjects();
      this.append('已创建工程 ' + name);
      this.openProject(name);
    });
  }

  importProjectDir(): void {
    pickFolderAndImport().then((err: string) => {
      if (err.length > 0) {
        this.append('导入失败：' + err);
        return;
      }
      this.projects = listProjects();
      this.append('已导入目录');
    });
  }

  saveDevices(list: string[]): void {
    this.devices = list;
    writePref('devices', JSON.stringify(list));
    AppStorage.setOrCreate('ide.devices', list);
    this.onChange();
  }

  // The address becomes the install target; the connection itself is made by the caller
  // through the worker, so this only records the outcome.
  saveDevice(value: string): void {
    this.device = value;
    writePref('device', value);
    this.setLink(2, '');
    this.append('设备通道 ' + value);
  }

  setLink(state: number, text: string): void {
    this.link = state;
    this.linkState = text;
    this.onChange();
  }

  // Reading the device log is a round trip like any other toolchain call, so it runs in
  // the worker; on the UI thread a slow device froze the whole page.
  private streamHandle: number = 0;
  private streamCursor: number = 0;
  private streamRunning: boolean = false;

  /// Opens a follower when the hilog pane becomes visible. libhvolt reads the device
  /// stream on its own thread; this side asks for the next lines and re-asks the moment an
  /// answer arrives, so the device's output sets the pace and nothing ticks on a timer.
  startLogStream(): void {
    this.stopLogStream();
    this.hlog = '读取中…';
    this.onChange();
    const params = JSON.stringify({
      device: this.device,
      level: this.logLevel.length === 0 ? undefined : this.logLevel,
      tag: this.logTag.length === 0 ? undefined : this.logTag,
      keywords: this.logKeywords
    });
    this.streamRunning = true;
    streamStartAsync(params, FILES, (raw: string) => {
      if (!this.streamRunning) {
        return;
      }
      let opened: StreamOpen = { code: -1, handle: 0, output: raw.substring(0, 200) };
      try {
        const parsed: StreamOpen = JSON.parse(raw) as StreamOpen;
        if (parsed.code !== undefined) {
          opened = parsed;
        }
      } catch (e) {
      }
      if (opened.code !== 0) {
        this.streamRunning = false;
        this.hlog = '流启动失败：' + (opened.output === undefined ? '' : opened.output);
        this.onChange();
        return;
      }
      this.streamHandle = opened.handle;
      this.streamCursor = 0;
      this.hlog = '';
      this.pull();
      this.onChange();
    });
  }

  stopLogStream(): void {
    this.streamRunning = false;
    if (this.streamHandle !== 0) {
      streamStop(this.streamHandle);
      this.streamHandle = 0;
    }
  }

  private pull(): void {
    if (!this.streamRunning || this.streamHandle === 0) {
      return;
    }
    const handle = this.streamHandle;
    streamNextAsync(handle, this.streamCursor, 200, 30000, (raw: string) => {
      if (!this.streamRunning || handle !== this.streamHandle) {
        return;
      }
      let page: StreamPage = { next: this.streamCursor, rows: [] };
      try {
        const parsed: StreamPage = JSON.parse(raw) as StreamPage;
        if (parsed.rows !== undefined) {
          page = parsed;
        }
      } catch (e) {
      }
      if (page.rows.length > 0) {
        this.streamCursor = page.next;
        const limit = AppStorage.get<number>(KEY_TAIL) ?? 300;
        const kept = this.hlog.length === 0 ? [] : this.hlog.split('\n');
        for (const line of page.rows) {
          kept.push(line);
        }
        while (kept.length > limit) {
          kept.shift();
        }
        this.hlog = kept.join('\n');
        this.onChange();
      }
      this.pull();
    });
  }

  loadDeviceLogs(): void {
    this.hlog = '读取中…';
    this.onChange();
    const tail = AppStorage.get<number>(KEY_TAIL) ?? 120;
    const argv = ['log', '-d', this.device, '--bundle', this.bundleId(), '--tail', '' + tail];
    hvoltAsync(argv, FILES, FILES, (raw: string) => {
      try {
        const r = this.fromEnvelope(raw);
        this.hlog = r.code === 0
          ? (r.output.length === 0 ? '（无输出）' : r.output)
          : ('hilog 读取失败：' + r.output);
      } catch (e) {
        this.hlog = 'hilog 读取失败：回调异常';
      }
      this.onChange();
    });
  }

  // `&entry/src/main/ets/pages/Index&` carries the module and the whole source path; the tree
  // row only has room for the part that distinguishes records within one file.
  private readableRecord(name: string): string {
    if (name.length < 2 || !name.startsWith('&') || !name.endsWith('&')) {
      return name;
    }
    const inner = name.substring(1, name.length - 1);
    const parts: string[] = inner.split('/');
    if (parts.length <= 2) {
      return inner;
    }
    const module = parts[0];
    const tail = parts[parts.length - 2] + '/' + parts[parts.length - 1];
    return module + ' › ' + tail;
  }

  private stripExtensionOf(path: string): string {
    const slash = path.lastIndexOf('/');
    const dot = path.lastIndexOf('.');
    return dot > slash ? path.substring(0, dot) : path;
  }

  outlineAbc(): string {
    for (const rel of this.files) {
      if (rel.endsWith('.abc')) {
        return this.dir() + '/' + rel;
      }
    }
    return '';
  }

  loadOutline(): void {
    if (this.project.length === 0 || this.current.length === 0) {
      this.outline = [];
      this.outlineNote = '未打开文件';
      this.onChange();
      return;
    }
    const abc = this.outlineAbc();
    if (abc.length === 0) {
      this.outline = [];
      this.outlineNote = '先构建';
      this.onChange();
      return;
    }
    const want = this.current;
    hvoltAsync(['abc-records', abc], this.dir(), FILES, (raw: string) => {
      const r = this.fromEnvelope(raw);
      if (r.code !== 0) {
        this.outline = [];
        this.outlineNote = 'abc-records 失败';
        this.onChange();
        return;
      }
      const names: string[] = [];
      // abc-records reports the source as the compiler saw it (`pages/Index.ts`), while the tree
      // holds `src/main/ets/pages/Index.ets`: compare without the extension, suffix either way.
      const wantStem = this.stripExtensionOf(want);
      const lines: string[] = r.output.split('\n');
      for (const line of lines) {
        const tab = line.indexOf('\t');
        if (tab < 0) {
          continue;
        }
        const name = line.substring(0, tab).trim();
        const file = line.substring(tab + 1).trim();
        if (file === '-') {
          continue;
        }
        const fileStem = this.stripExtensionOf(file);
        if (fileStem === wantStem || wantStem.endsWith('/' + fileStem) ||
          fileStem.endsWith('/' + wantStem) || name.indexOf(wantStem) >= 0) {
          names.push(this.readableRecord(name));
        }
      }
      this.outline = names;
      this.outlineNote = names.length === 0 ? '该文件无 record' : '';
      this.onChange();
    });
  }

  private begin(label: string): boolean {
    if (this.busy) {
      return false;
    }
    this.busy = true;
    // Every task starts from an empty log. Left in place, the previous run's output sits
    // above the new one and reads as part of this attempt.
    this.log = '';
    this.statusText = label;
    this.statusTone = 1;
    this.onChange();
    return true;
  }

  private end(r: ActionResult, ok: string, fail: string): void {
    const body = 'code=' + r.code + ' · ' + r.ms + 'ms\n' + r.output;
    this.log = withLine(this.log, body);
    // The panel lives in this process only: when a task's own failure ends the process, the
    // reason would leave nothing to read from outside. Mirror it in chunks so hilog's fixed
    // line limit does not cut the middle out of a toolchain error.
    const CHUNK: number = 800;
    for (let at = 0; at < body.length; at += CHUNK) {
      hilog.info(0x0000, 'hvoltide', 'OUT %{public}s', body.substring(at, at + CHUNK));
    }
    this.statusText = r.code === 0 ? ok : fail;
    this.statusTone = r.code === 0 ? 2 : 3;
    this.busy = false;
    this.onChange();
  }

  // Every one of these goes through the worker: the toolchain call is synchronous, and a
  // build or a push holds it far longer than the six seconds the system allows the UI
  // thread to stay blocked.
  build(onBuild: (code: number) => void): void {
    if (!this.begin('构建中')) {
      return;
    }
    // Waits for the write: starting the build while the buffer was still being written made
    // the compiler read the previous file contents.
    this.flushThen(() => {
      hvoltAsync(['build'], this.dir(), FILES, (raw: string) => {
        const r = this.fromEnvelope(raw);
        this.end(r, '已构建', '构建失败');
        onBuild(r.code);
      });
    });
  }

  // `hvolt run` only pushes an already signed package, so the chain is build → sign →
  // run. The signature comes from AGC (remote signing); without a login this step fails
  // and says so rather than pushing an unsigned package the device would reject.
  deploy(): void {
    // Checked first: running build and AGC signing only to fail at push wastes the whole
    // chain, and the missing link is visible before it starts.
    if (this.link !== 2) {
      this.statusText = '未连接设备';
      this.statusTone = 3;
      this.append('deploy skipped: 未连接设备，先连接再部署');
      this.onChange();
      return;
    }
    if (!this.begin('构建中')) {
      return;
    }
    this.flushThen(() => this.deployAfterFlush());
  }

  // Order matters: `hvolt build` only signs when the project already carries an
  // [app.signing] table, and that table is written by `hvolt sign` when it provisions the
  // materials. Building first leaves the package unsigned and the deploy dies on
  // "签名未产出包" every first time, so the materials come first and the build after them.
  private deployAfterFlush(): void {
    this.statusText = '准备签名材料';
    this.onChange();
    hvoltAsync(['sign'], this.dir(), FILES, (prepared: string) => {
      const prep = this.fromEnvelope(prepared);
      if (prep.code !== 0) {
        this.end(prep, '已部署', '签名材料失败');
        return;
      }
      this.statusText = '构建中';
      this.onChange();
      hvoltAsync(['build'], this.dir(), FILES, (built: string) => {
        const b = this.fromEnvelope(built);
        if (b.code !== 0) {
          this.end(b, '已部署', '构建失败');
          return;
        }
        this.statusText = '安装中';
        this.onChange();
        this.logBuildDir();
        const hap: string = this.signedHap();
        if (hap.length === 0) {
          this.statusText = '签名未产出包';
          this.statusTone = 3;
          this.busy = false;
          this.onChange();
          return;
        }
        // Install only: launching the app is the user's call, not a side effect of deploying.
        hvoltAsync(['push', this.device, '--hap', hap], this.dir(), FILES, (ran: string) => {
          this.end(this.fromEnvelope(ran), '已部署', '部署失败');
        });
      });
    });
  }

  // What a build actually produced. Without it a missing package only shows up as a
  // "not found" from the push, one step after the fact.
  // The signed package a deploy should push: the module's own if it is there, otherwise the
  // single signed HAP present. Returns '' when a build produced none, which is the one case
  // worth stopping on — pushing a path that may not exist is what turned a missing file into
  // a panic downstream.
  private signedHap(): string {
    const build = this.dir() + '/build';
    let names: string[] = [];
    try {
      names = fs.listFileSync(build);
    } catch (e) {
      return '';
    }
    const signed: string[] = names.filter((n: string) => n.endsWith('-signed.hap'));
    this.append('signed: ' + (signed.length === 0 ? '(无)' : signed.join(' ')));
    if (signed.length === 0) {
      return '';
    }
    const module: string = this.moduleName();
    for (const name of signed) {
      if (name === module + '-signed.hap') {
        return build + '/' + name;
      }
    }
    return signed.length === 1 ? build + '/' + signed[0] : '';
  }

  private moduleName(): string {
    try {
      const text: string = fs.readTextSync(this.dir() + '/hvolt.toml');
      const at: number = text.indexOf('[module]');
      if (at < 0) {
        return 'entry';
      }
      const rest: string = text.substring(at);
      const hit: number = rest.indexOf('name = "');
      if (hit < 0) {
        return 'entry';
      }
      const from: number = hit + 8;
      return rest.substring(from, rest.indexOf('"', from));
    } catch (e) {
      return 'entry';
    }
  }

  private logBuildDir(): void {
    const dir = this.dir() + '/build';
    try {
      const names: string[] = fs.listFileSync(dir);
      this.append('build: ' + (names.length === 0 ? '(空)' : names.join(' ')));
    } catch (e) {
      this.append('build: 读不到 ' + dir);
    }
  }

  install(): void {
    if (!this.begin('安装中')) {
      return;
    }
    const hap: string = this.signedHap();
    if (hap.length === 0) {
      this.statusText = '没有签名包';
      this.statusTone = 3;
      this.busy = false;
      this.onChange();
      return;
    }
    hvoltAsync(['push', this.device, '--hap', hap], this.dir(), FILES, (raw: string) => {
      this.end(this.fromEnvelope(raw), '已安装', '安装失败');
    });
  }

  launch(): void {
    if (!this.begin('启动中')) {
      return;
    }
    hvoltAsync(['start', this.bundleId() + '/EntryAbility', '-d', this.device], this.dir(), FILES,
      (raw: string) => {
        this.end(this.fromEnvelope(raw), '已启动', '启动失败');
      });
  }

  // Anything that is not the toolchain's JSON envelope is reported as a failure instead
  // of throwing, so a bad reply cannot leave a command stuck in its "running" label.
  private jsonLine(text: string): string {
    const start = text.indexOf('{');
    const end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return text.trim();
    }
    return text.substring(start, end + 1);
  }

  private fromEnvelope(raw: string): ActionResult {
    try {
      const parsed: HvoltResult = JSON.parse(raw) as HvoltResult;
      const out: ActionResult = {
        code: parsed.code === undefined ? -1 : parsed.code,
        output: parsed.output === undefined ? raw : parsed.output,
        ms: 0
      };
      return out;
    } catch (e) {
      const out: ActionResult = { code: -1, output: raw.substring(0, 400), ms: 0 };
      return out;
    }
  }

  // AGC talks to the network; both the login and the status query run in the worker so
  // the sheet stays responsive while the request is in flight.
  //
  // The authorization page is loaded in the app's own WebView: the redirect it makes to
  // 127.0.0.1 carries the tempToken, and that request is intercepted inside the sandbox.
  // No external browser, no listener that a browser on another host could never reach.
  loginAgc(): void {
    this.agcState = '获取授权地址…';
    this.onChange();
    hvoltAsync(['agc', 'login', '--print-url'], FILES, FILES, (raw: string) => {
      const r = this.fromEnvelope(raw);
      // The captured stdout can carry noise from other threads, so the JSON is picked out
      // by its first brace rather than parsed off the whole string.
      const line = this.jsonLine(r.output);
      let port = 0;
      try {
        const info: AgcAuthInfo = JSON.parse(line) as AgcAuthInfo;
        port = info.port;
        this.agcUrl = info.url;
        this.agcState = '等待授权';
      } catch (e) {
        this.agcState = '获取授权地址失败：' + r.output;
        this.onChange();
        return;
      }
      this.onChange();
      // The page redirects to this device's own loopback, so the listener runs here and
      // only the page is shown in the WebView.
      hvoltAsync(['agc', 'login', '--wait', '' + port], FILES, FILES, (done: string) => {
        const finished = this.fromEnvelope(done);
        this.agcUrl = '';
        this.append(finished.output.trim());
        this.queryAgc();
      });
    });
  }

  /// Called from the WebView the moment it sees the redirect; the URL itself is the
  /// credential hand-off, so it is passed straight to the token exchange.
  completeAgcLogin(callbackUrl: string): void {
    this.agcUrl = '';
    this.agcState = '换取 token…';
    this.onChange();
    hvoltAsync(['agc', 'login', '--callback', callbackUrl], FILES, FILES, (raw: string) => {
      const r = this.fromEnvelope(raw);
      this.append(r.output.trim());
      this.queryAgc();
    });
  }

  // Credentials live in the sandbox's own ~/.hvolt/auth.json; signing out is removing it.
  logoutAgc(): void {
    try {
      const path = FILES + '/.hvolt/auth.json';
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      this.agcUser = '';
      this.agcState = '未登录';
    } catch (e) {
      this.agcState = '登出失败';
    }
    this.onChange();
  }

  queryAgc(): void {
    hvoltAsync(['agc', 'whoami'], FILES, FILES, (raw: string) => {
      const r = this.fromEnvelope(raw);
      const text = r.output;
      const at = text.indexOf('User ID:');
      if (r.code === 0 && at >= 0) {
        const rest = text.substring(at + 'User ID:'.length).trim();
        const end = rest.search(/\s/);
        this.agcUser = end > 0 ? rest.substring(0, end) : rest;
        this.agcState = '已登录';
      } else {
        this.agcUser = '';
        this.agcState = '未登录';
      }
      this.onChange();
    });
    // Boot does not wait on AGC: the query reaches the network when a backend exists, and
    // the status line only needs a starting value. The sheet refreshes it on open.
    // The token lives in the sandbox and survives a restart, so the account is read back
    // on boot instead of waiting for the user to press log in again.
    this.agcState = '查询中';
    this.onChange();
  }
}

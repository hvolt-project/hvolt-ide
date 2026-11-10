// Editor and shell options. Each one is a persisted value with a single writer (the
// settings sheet) and subscribers through AppStorage, so a change lands in the editor,
// the build or the log panel immediately and survives a restart.
import web_webview from '@ohos.web.webview';
import fs from '@ohos.file.fs';
import { readPref, writePref } from './Prefs';
import { projectDir } from './Project';

export const KEY_FONT: string = 'opt.fontSize';
export const KEY_LINES: string = 'opt.lineNumbers';
export const KEY_WRAP: string = 'opt.wordWrap';
export const KEY_TAB: string = 'opt.tabSize';
export const KEY_AUTOSAVE: string = 'opt.autoSave';
export const KEY_OBFUSCATE: string = 'opt.obfuscate';
export const KEY_AUTOCONNECT: string = 'opt.autoConnect';
export const KEY_TAIL: string = 'opt.logTail';
export const KEY_SAVE_ON_SWITCH: string = 'opt.saveOnSwitch';

export const FONT_SIZES: number[] = [12, 14, 16, 18, 20];
export const TAB_SIZES: number[] = [2, 4];
export const TAILS: number[] = [50, 120, 300];

export class ShellOptions {
  fontSize: number = 14;
  lineNumbers: boolean = true;
  wordWrap: boolean = true;
  tabSize: number = 2;
  autoSave: boolean = true;
  saveOnSwitch: boolean = true;
  obfuscate: boolean = false;
  autoConnect: boolean = true;
  logTail: number = 120;
}

function flag(value: string): boolean {
  return value === '1';
}

// Reads every option once at start-up; the file is the only source, no in-code defaults
// besides the class field values above.
export async function loadOptions(): Promise<ShellOptions> {
  const o = new ShellOptions();
  o.fontSize = Number(await readPref(KEY_FONT, '14'));
  o.lineNumbers = flag(await readPref(KEY_LINES, '1'));
  o.wordWrap = flag(await readPref(KEY_WRAP, '1'));
  o.tabSize = Number(await readPref(KEY_TAB, '2'));
  o.autoSave = flag(await readPref(KEY_AUTOSAVE, '1'));
  o.obfuscate = flag(await readPref(KEY_OBFUSCATE, '0'));
  o.autoConnect = flag(await readPref(KEY_AUTOCONNECT, '1'));
  o.logTail = Number(await readPref(KEY_TAIL, '120'));
  o.saveOnSwitch = flag(await readPref(KEY_SAVE_ON_SWITCH, '1'));
  publishOptions(o);
  return o;
}

export function publishOptions(o: ShellOptions): void {
  AppStorage.setOrCreate(KEY_FONT, o.fontSize);
  AppStorage.setOrCreate(KEY_LINES, o.lineNumbers ? '1' : '0');
  AppStorage.setOrCreate(KEY_WRAP, o.wordWrap ? '1' : '0');
  AppStorage.setOrCreate(KEY_TAB, o.tabSize);
  AppStorage.setOrCreate(KEY_AUTOSAVE, o.autoSave ? '1' : '0');
  AppStorage.setOrCreate(KEY_OBFUSCATE, o.obfuscate ? '1' : '0');
  AppStorage.setOrCreate(KEY_AUTOCONNECT, o.autoConnect ? '1' : '0');
  AppStorage.setOrCreate(KEY_TAIL, o.logTail);
  AppStorage.setOrCreate(KEY_SAVE_ON_SWITCH, o.saveOnSwitch ? '1' : '0');
}

export function saveOption(key: string, value: string): void {
  writePref(key, value);
}

// Monaco owns its own layout; the shell hands over the option set as one call so the
// editor never sees a half-applied state.
export function applyEditorOptions(
  controller: web_webview.WebviewController,
  o: ShellOptions,
  report: (line: string) => void): void {
  const script = 'hvoltApplyOptions(' + JSON.stringify({
    fontSize: o.fontSize,
    lineNumbers: o.lineNumbers,
    wordWrap: o.wordWrap,
    tabSize: o.tabSize
  }) + ')';
  // The controller is only bound while a Web component is on screen; asking it to run a
  // script in the empty state throws 17100001 and takes the process down.
  try {
    controller.runJavaScript(script).catch((e: Error) => {
      report('options: ' + e.message);
    });
  } catch (e) {
    report('options: ' + (e as Error).message);
  }
}

// Obfuscation is a project property (module level in hvolt.toml), not a shell preference:
// toggling it edits the file the build reads.
export function setObfuscation(project: string, on: boolean): boolean {
  if (project.length === 0) {
    return false;
  }
  const path = projectDir(project) + '/src/hvolt.toml';
  try {
    const text = fs.readTextSync(path);
    const next = /^obfuscation\s*=\s*\w+/m.test(text)
      ? text.replace(/^obfuscation\s*=\s*\w+/m, 'obfuscation = ' + (on ? 'true' : 'false'))
      : text.replace(/^name\s*=\s*"[^"]*"/m, 'name = "entry"\nobfuscation = ' + (on ? 'true' : 'false'));
    const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, next);
    fs.closeSync(f);
    return true;
  } catch (e) {
    return false;
  }
}

export function readObfuscation(project: string): boolean {
  if (project.length === 0) {
    return false;
  }
  try {
    const text = fs.readTextSync(projectDir(project) + '/src/hvolt.toml');
    const m = /^obfuscation\s*=\s*(\w+)/m.exec(text);
    return m !== null && m[1] === 'true';
  } catch (e) {
    return false;
  }
}

import fs from '@ohos.file.fs';
import { picker } from '@kit.CoreFileKit';
import { ensureDir } from './Stage';
import { lastSegment } from './Util';
import { hvolt, hvoltArgv } from './Hvolt';
import { parseBundle } from './Commands';

export const STAGE_ROOT: string = getContext().filesDir + '/stage';

export function exists(path: string): boolean {
  try {
    fs.statSync(path);
    return true;
  } catch (e) {
    return false;
  }
}

// A project is any directory under the stage root that carries an hvolt.toml; the
// packaged samples land there on first launch, so the list is never hand-written.
export function listProjects(): string[] {
  const out: string[] = [];
  let names: string[] = [];
  try {
    names = fs.listFileSync(STAGE_ROOT);
  } catch (e) {
    return out;
  }
  for (const n of names) {
    if (exists(STAGE_ROOT + '/' + n + '/hvolt.toml')) {
      out.push(n);
    }
  }
  out.sort();
  return out;
}

export function projectDir(name: string): string {
  return STAGE_ROOT + '/' + name;
}

// New projects start from the packaged sample, so the first build in a fresh project
// already has a module config, an ability and a page to compile.
export async function createProject(name: string): Promise<string> {
  const clean = name.trim();
  if (clean.length === 0) {
    return '名称不能为空';
  }
  if (clean.indexOf('/') >= 0 || clean.indexOf(' ') >= 0) {
    return '名称不能含空格或斜杠';
  }
  const dir = projectDir(clean);
  if (exists(dir)) {
    return '已存在同名工程';
  }
  // `hvolt init` runs with the stage root as its working directory, so the root has to exist
  // before the first project is created.
  ensureDir(STAGE_ROOT);
  const r = hvolt(hvoltArgv(['init', clean]), STAGE_ROOT, STAGE_ROOT);
  if (r.code !== 0) {
    return '初始化失败 ' + r.output;
  }
  return exists(dir + '/hvolt.toml') ? '' : '未生成 hvolt.toml';
}

export function projectBundle(name: string, fallback: string): string {
  try {
    const text = fs.readTextSync(projectDir(name) + '/hvolt.toml');
    return parseBundle(text, fallback);
  } catch (e) {
    return fallback;
  }
}

export function projectSourceCount(name: string): number {
  const out: string[] = [];
  countSources(projectDir(name) + '/src', out);
  return out.length;
}

function countSources(dir: string, out: string[]): void {
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    return;
  }
  for (const n of names) {
    const full = dir + '/' + n;
    try {
      if (fs.statSync(full).isDirectory()) {
        countSources(full, out);
      } else {
        out.push(n);
      }
    } catch (e) {
    }
  }
}

function copyTreeUri(src: string, dst: string): void {
  ensureDir(dst);
  let names: string[] = [];
  try {
    names = fs.listFileSync(src);
  } catch (e) {
    return;
  }
  for (const n of names) {
    const from = src + '/' + n;
    const to = dst + '/' + n;
    let isDir = false;
    try {
      isDir = fs.statSync(from).isDirectory();
    } catch (e) {
      continue;
    }
    if (isDir) {
      copyTreeUri(from, to);
    } else {
      fs.copyFileSync(from, to);
    }
  }
}

// The toolchain only builds inside its own sandbox, so a picked folder is copied in
// rather than referenced. A folder without hvolt.toml is refused instead of being
// turned into an empty project.
export async function importDir(uri: string): Promise<string> {
  const trimmed = uri.charAt(uri.length - 1) === '/'
    ? uri.substring(0, uri.length - 1) : uri;
  const name = lastSegment(trimmed);
  if (name.length === 0) {
    return '目录名为空';
  }
  if (!exists(trimmed + '/hvolt.toml')) {
    return '该目录没有 hvolt.toml';
  }
  const dst = projectDir(name);
  if (exists(dst)) {
    return '已存在同名工程';
  }
  try {
    copyTreeUri(trimmed, dst);
  } catch (e) {
    return '复制失败 ' + (e as Error).message;
  }
  return exists(dst + '/hvolt.toml') ? '' : '复制不完整';
}


// Bitmaps are opened for viewing, never for editing: the text editor decodes as UTF-8 and
// writes back the same string, which corrupts the bytes of an image the moment it is saved.
// Decided by the bytes, not the name: a `.png` that is really text should open as text, and
// an extensionless file that really is a PNG should preview. Reading 12 bytes settles it and
// costs less than decoding a wrong guess into the editor buffer.
export function isImageFile(dir: string, rel: string): boolean {
  let head: Uint8Array;
  try {
    const file = fs.openSync(dir + '/' + rel, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(12);
    const n = fs.readSync(file.fd, buf);
    fs.closeSync(file);
    head = new Uint8Array(buf.slice(0, n));
  } catch (e) {
    return false;
  }
  const n = head.length;
  if (n >= 8 && head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47) {
    return true;
  }
  if (n >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
    return true;
  }
  if (n >= 6 && head[0] === 0x47 && head[1] === 0x49 && head[2] === 0x46) {
    return true;
  }
  if (n >= 12 && head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46 &&
    head[8] === 0x57 && head[9] === 0x45 && head[10] === 0x42 && head[11] === 0x50) {
    return true;
  }
  return n >= 2 && head[0] === 0x42 && head[1] === 0x4d;
}

// Text editors only: a NUL byte in the first 512 means the buffer is not text, and writing
// it back through the text pipeline would corrupt the file. Images are previewed before this
// check, so this only catches the rest.
export function isBinaryFile(dir: string, rel: string): boolean {
  try {
    const file = fs.openSync(dir + '/' + rel, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(512);
    const n = fs.readSync(file.fd, buf);
    fs.closeSync(file);
    const head = new Uint8Array(buf.slice(0, n));
    for (let i = 0; i < head.length; i++) {
      if (head[i] === 0) {
        return true;
      }
    }
    return false;
  } catch (e) {
    return false;
  }
}

export function imageUri(name: string, rel: string): string {
  return 'file://' + projectDir(name) + '/' + rel;
}

// Byte length only — the caller wants a size for the preview header, not the contents.
export function fileSize(name: string, rel: string): number {
  try {
    return fs.statSync(projectDir(name) + '/' + rel).size;
  } catch (e) {
    return 0;
  }
}

export function readSource(name: string, rel: string): string {
  return fs.readTextSync(projectDir(name) + '/' + rel);
}

export function writeSource(name: string, rel: string, text: string): boolean {
  try {
    const file = fs.openSync(projectDir(name) + '/' + rel,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, text);
    fs.closeSync(file);
    return true;
  } catch (e) {
    return false;
  }
}

// Removing a project deletes its directory in the stage root. The caller confirms first;
// this only reports whether the tree is gone.
export function deleteProject(name: string): boolean {
  try {
    fs.rmdirSync(projectDir(name));
    return true;
  } catch (e) {
    return false;
  }
}

// File-level edits from the tree. The caller confirms a delete first; nothing here asks.
export function deleteTreeEntry(name: string, rel: string): boolean {
  try {
    fs.unlinkSync(projectDir(name) + '/' + rel);
    return true;
  } catch (e) {
    return false;
  }
}

// An empty file, not a template: which boilerplate belongs in a new source file is the
// user's call, and guessing one would put text into a file they did not write.
export function createTreeFile(name: string, dirRel: string, fileName: string): boolean {
  const path = dirRel.length === 0 ? projectDir(name) + '/' + fileName
    : projectDir(name) + '/' + dirRel + '/' + fileName;
  try {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.closeSync(file);
    return true;
  } catch (e) {
    return false;
  }
}

// Copies picked files into the tree. Name clashes get a numeric suffix instead of being
// overwritten, since the picked file is not recoverable once replaced.
export async function pickFilesInto(name: string, dirRel: string): Promise<string> {
  let uris: string[] = [];
  try {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 20;
    options.selectMode = picker.DocumentSelectMode.FILE;
    const view = new picker.DocumentViewPicker(getContext());
    uris = await view.select(options);
  } catch (e) {
    return '选择器不可用 ' + (e as Error).message;
  }
  if (uris.length === 0) {
    return '已取消';
  }
  const dstDir = dirRel.length === 0 ? projectDir(name) : projectDir(name) + '/' + dirRel;
  let copied = 0;
  let failed = 0;
  for (const uri of uris) {
    const base = lastSegment(decodeURIComponent(uri));
    if (base.length === 0) {
      failed++;
      continue;
    }
    let target = dstDir + '/' + base;
    let n = 1;
    while (exists(target)) {
      const dot = base.lastIndexOf('.');
      const stem = dot > 0 ? base.substring(0, dot) : base;
      const ext = dot > 0 ? base.substring(dot) : '';
      target = dstDir + '/' + stem + '-' + n + ext;
      n++;
    }
    try {
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const dst = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const buf = new ArrayBuffer(64 * 1024);
      let read = 0;
      while ((read = fs.readSync(src.fd, buf)) > 0) {
        fs.writeSync(dst.fd, buf, { length: read });
      }
      fs.closeSync(src);
      fs.closeSync(dst);
      copied++;
    } catch (e) {
      failed++;
    }
  }
  return failed === 0 ? '导入 ' + copied + ' 个文件' : '导入 ' + copied + ' 个，失败 ' + failed + ' 个';
}

// Picking a folder needs the system picker; the result is copied into the stage root
// because the toolchain only builds paths it owns. Returns '' on success.
export async function pickFolderAndImport(): Promise<string> {
  let uri = '';
  try {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const view = new picker.DocumentViewPicker(getContext());
    const uris = await view.select(options);
    if (uris.length === 0) {
      return '已取消';
    }
    uri = uris[0];
  } catch (e) {
    return '选择器不可用 ' + (e as Error).message;
  }
  return importDir(uri);
}

// Importing an SDK the app did not ship with.
//
// The bundled SDK is a lookup table: it carries the platform `.d.ts` files and an index, but no HMS
// components at all (no `hms/ets/api`), which is why a project that imports a HMS kit cannot be
// built here and why the live-view API is unreachable. The fix is to let the operator bring a full
// SDK in, rather than growing the package by tens of megabytes for everyone.
//
// The engine resolves the SDK at a fixed path (`<filesDir>/.hvolt/sdk`) and was not built to take a
// path parameter, so an import swaps that directory rather than pointing somewhere else. The archive
// it came from is kept under `filesDir/sdk/<version>.zip` so the choice is reproducible and can be
// rolled back by unzipping it again.
//
// What makes an archive acceptable is checked before anything is swapped: an SDK that is missing its
// type declarations would build less than the bundled one, and silently replacing a working tree with
// a broken one is worse than refusing the import.

import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { picker } from '@kit.CoreFileKit';
import { FILES } from './Stage';

/** Where the engine looks, and where imports are archived. */
const SDK_DIR: string = FILES + '/.hvolt/sdk';
const STAGE_DIR: string = FILES + '/.hvolt/sdk.new';
const BACKUP_DIR: string = FILES + '/.hvolt/sdk.bundled';
const ARCHIVE_DIR: string = FILES + '/sdk';

/** Files an SDK must have before it is allowed to replace the bundled one. */
const REQUIRED: string[] = [
  'oh-uni-package.json',
  'openharmony/ets/api',
  'hms/ets/api'
];

export interface SdkImportResult {
  ok: boolean;
  /** One line for the settings row: what happened, or which requirement was missing. */
  message: string;
  /** Version string read from the archive, empty when the import failed. */
  version: string;
}

function exists(path: string): boolean {
  try {
    fs.accessSync(path);
    return true;
  } catch (e) {
    return false;
  }
}

function rmTree(path: string): void {
  let isDir = false;
  try {
    isDir = fs.statSync(path).isDirectory();
  } catch (e) {
    // Already gone: nothing left to remove.
    return;
  }
  if (!isDir) {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // Same reasoning as above.
    }
    return;
  }
  let entries: string[] = [];
  try {
    entries = fs.listFileSync(path);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    rmTree(path + '/' + name);
  }
  try {
    fs.rmdirSync(path);
  } catch (e) {
    // A file holds the directory open; the caller reports the swap that follows.
  }
}

/** `JSON.stringify` of a BusinessError is `{}` — its fields are not enumerable — so a failed
 *  rename would read as "替换失败：{}" with the reason lost. Prefer the reported code and message. */
function errText(e: Object): string {
  const be = e as Record<string, Object>;
  const code = be['code'];
  const message = be['message'];
  if (message !== undefined && message !== null) {
    return code === undefined && code === null ? String(message) : String(code) + ' ' + String(message);
  }
  return JSON.stringify(e);
}

/** Moves `from` onto `to`, replacing it. `renameSync` is used rather than a copy so a 20-40 MB SDK
 *  does not have to be written twice on a phone. */
function replaceDir(from: string, to: string): void {
  if (exists(to)) {
    if (exists(BACKUP_DIR)) {
      rmTree(BACKUP_DIR);
    }
    fs.renameSync(to, BACKUP_DIR);
  }
  fs.renameSync(from, to);
}

/** zlib writes into an existing directory; a leftover half-unpacked tree would make the
 *  requirement check pass on files from a previous, different archive. */
function freshDir(path: string): void {
  if (exists(path)) {
    rmTree(path);
  }
  fs.mkdirSync(path, true);
}

/** This runtime has `readTextSync` but no `writeFileSync` (measured on device:
 *  "writeFileSync is not callable"), so whole-file writes go through an fd, as elsewhere. */
function writeText(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
}

function copyFile(from: string, to: string): void {
  const input = fs.openSync(from, fs.OpenMode.READ_ONLY);
  const output = fs.openSync(to, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  const buffer = new ArrayBuffer(1 << 16);
  let read = fs.readSync(input.fd, buffer);
  while (read > 0) {
    fs.writeSync(output.fd, buffer, { length: read });
    read = fs.readSync(input.fd, buffer);
  }
  fs.closeSync(output);
  fs.closeSync(input);
}

function readVersion(root: string): string {
  try {
    const text = fs.readTextSync(root + '/oh-uni-package.json');
    const parsed = JSON.parse(text) as Record<string, Object>;
    const version = parsed['version'];
    return version === undefined || version === null ? '' : (version as string);
  } catch (e) {
    return '';
  }
}

/** The zip may wrap everything in one top-level directory; that wrapper is not part of the layout
 *  the engine expects, so it is stripped by copying the single subdirectory up one level. */
function unwrapSingleDir(root: string): string {
  let entries: string[] = [];
  try {
    entries = fs.listFileSync(root);
  } catch (e) {
    return root;
  }
  if (entries.length !== 1) {
    return root;
  }
  const only = root + '/' + entries[0];
  try {
    if (!fs.statSync(only).isDirectory()) {
      return root;
    }
  } catch (e) {
    return root;
  }
  return only;
}

function missingRequirement(root: string): string {
  for (const rel of REQUIRED) {
    if (!exists(root + '/' + rel)) {
      return rel;
    }
  }
  return '';
}

/** Opens the picker, copies the chosen archive in, unpacks it beside the live tree, checks the
 *  layout and only then swaps it in. Every failure leaves the previous SDK untouched. */
export async function importSdk(): Promise<SdkImportResult> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  options.fileSuffixFilters = ['.zip'];
  let urls: string[] = [];
  try {
    const viewPicker = new picker.DocumentViewPicker();
    urls = await viewPicker.select(options);
  } catch (e) {
    return { ok: false, message: '未选择文件', version: '' };
  }
  if (urls.length === 0) {
    return { ok: false, message: '未选择文件', version: '' };
  }

  const staging = FILES + '/.hvolt/import-sdk.zip';
  try {
    copyFile(urls[0], staging);
  } catch (e) {
    return { ok: false, message: '复制失败：' + errText(e), version: '' };
  }

  freshDir(STAGE_DIR);
  try {
    await zlib.decompressFile(staging, STAGE_DIR);
  } catch (e) {
    rmTree(STAGE_DIR);
    return { ok: false, message: '解压失败：' + errText(e), version: '' };
  }

  const root = unwrapSingleDir(STAGE_DIR);
  const missing = missingRequirement(root);
  if (missing.length > 0) {
    rmTree(STAGE_DIR);
    return { ok: false, message: '缺少 ' + missing + '，未替换', version: '' };
  }

  const version = readVersion(root);
  const label = version.length > 0 ? version : 'imported';
  const stamp = FILES + '/.hvolt/sdk.stamp';
  try {
    if (root !== STAGE_DIR) {
      // The single wrapper directory becomes the tree: renaming is enough, and it keeps the tree
      // where the swap below expects it.
      fs.renameSync(root, FILES + '/.hvolt/sdk.wrap');
      rmTree(STAGE_DIR);
      fs.renameSync(FILES + '/.hvolt/sdk.wrap', STAGE_DIR);
    }
    replaceDir(STAGE_DIR, SDK_DIR);
    // The stamp is what the first-launch unpacker compares; writing an import marker stops it from
    // re-unpacking the bundled archive over the imported tree on the next start.
    try {
      writeText(stamp, 'imported:' + label);
    } catch (e) {
      // A missing stamp only means the next start may unpack the bundled archive again; the
      // imported tree is already in place, so this must not fail the import.
    }
    // The copy of the source archive is a convenience for rolling back, not a condition: it once
    // reported a successful swap as `替换失败` (139000002 on the archive path).
    try {
      if (!exists(ARCHIVE_DIR)) {
        fs.mkdirSync(ARCHIVE_DIR, true);
      }
      copyFile(staging, ARCHIVE_DIR + '/' + label + '.zip');
    } catch (e) {
      // Keep going: the SDK tree itself has been swapped in above.
    }
  } catch (e) {
    return { ok: false, message: '替换失败：' + errText(e), version: version };
  } finally {
    try {
      fs.unlinkSync(staging);
    } catch (e) {
      // Nothing to clean up.
    }
  }
  const hms = exists(SDK_DIR + '/hms/ets/api') ? '含 HMS' : '无 HMS';
  return {
    ok: true,
    message: '已导入 ' + label + '（' + hms + '），工程已用新 SDK',
    version: label
  };
}

/** What the settings row shows about the live tree, read from disk rather than remembered. */
export function sdkStatus(): string {
  if (!exists(SDK_DIR)) {
    return '未解包';
  }
  const version = readVersion(SDK_DIR);
  const hms = exists(SDK_DIR + '/hms/ets/api');
  const imported = exists(FILES + '/.hvolt/sdk.stamp');
  return (version.length > 0 ? version : '未知版本') + (hms ? ' · 含 HMS' : ' · 无 HMS') +
    (imported ? ' · 外部导入' : '');
}
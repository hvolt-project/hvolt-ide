import fs from '@ohos.file.fs';
import { resourceManager } from '@kit.LocalizationKit';
import zlib from '@ohos.zlib';

export const FILES: string = getContext().filesDir;
export const STAGE: string = FILES + '/stage';
export const PROJ: string = STAGE + '/proj';

export function ensureDir(path: string): void {
  const parts: string[] = path.split('/');
  let cur: string = '';
  for (const p of parts) {
    if (p.length === 0) {
      cur = '/';
      continue;
    }
    cur = cur === '/' ? '/' + p : (cur.length === 0 ? p : cur + '/' + p);
    try {
      fs.mkdirSync(cur);
    } catch (e) {
    }
  }
}

// A rawfile entry is a directory when it has children; recursion stops at files.
export async function copyRaw(rm: resourceManager.ResourceManager, prefix: string, dstDir: string): Promise<void> {
  ensureDir(dstDir);
  let names: string[] = [];
  try {
    names = await rm.getRawFileList(prefix);
  } catch (e) {
    names = [];
  }
  for (const n of names) {
    const src = prefix.length === 0 ? n : prefix + '/' + n;
    const dst = dstDir + '/' + n;
    let childCount = -1;
    try {
      const child = await rm.getRawFileList(src);
      childCount = child.length;
    } catch (e) {
      childCount = -1;
    }
    if (childCount >= 0) {
      ensureDir(dst);
      await copyRaw(rm, src, dst);
      continue;
    }
    const bytes: Uint8Array = await rm.getRawFileContent(src);
    const f: fs.File = fs.openSync(dst,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
    fs.closeSync(f);
  }
}

export function listSources(dir: string, prefix: string, out: string[]): void {
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    return;
  }
  names.sort();
  for (const name of names) {
    const full = dir + '/' + name;
    let isDir: boolean = false;
    try {
      isDir = fs.statSync(full).isDirectory();
    } catch (e) {
      continue;
    }
    const rel = prefix.length === 0 ? name : prefix + '/' + name;
    if (isDir) {
      listSources(full, rel, out);
    } else {
      out.push(rel);
    }
  }
}

// The SDK ships as one archive rather than a tree of rawfiles: 55 loose files under
// `rawfile/` cost a rawfile listing entry each, and unpacking writes the same bytes anyway.
const SDK_ARCHIVE: string = 'sdk.zip';
const SDK_STAMP: string = 'sdk.stamp';
// Bump when the archive's contents change; a mismatch re-unpacks over the old tree.
const SDK_VERSION: string = '26.0.0-1';

function sdkStampPath(): string {
  return FILES + '/.hvolt/' + SDK_STAMP;
}

function sdkUpToDate(): boolean {
  try {
    return fs.readTextSync(sdkStampPath()) === SDK_VERSION;
  } catch (e) {
    return false;
  }
}

function unpackSdk(rm: resourceManager.ResourceManager): Promise<void> {
  const archive = FILES + '/.hvolt/' + SDK_ARCHIVE;
  return rm.getRawFileContent(SDK_ARCHIVE).then((content: Uint8Array) => {
    const file = fs.openSync(archive, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, content.buffer);
    fs.closeSync(file);
    const dst = FILES + '/.hvolt/sdk';
    ensureDir(dst);
    return zlib.decompressFile(archive, dst).then(() => {
      const stamp = fs.openSync(sdkStampPath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(stamp.fd, SDK_VERSION);
      fs.closeSync(stamp);
      fs.unlinkSync(archive);
    });
  });
}

// First launch unpacks the SDK lookup tables into the sandbox; projects are created
// through `hvolt init` and the host key is generated on demand, so nothing else is
// shipped in the rawfile. A stamp written after a successful unpack keeps later launches
// from repeating the write.
export function stageProject(done: () => void, fail: (msg: string) => void): void {
  const rm = getContext().resourceManager;
  ensureDir(FILES + '/.hvolt');
  ensureDir(FILES + '/.harmony');
  if (sdkUpToDate()) {
    done();
    return;
  }
  unpackSdk(rm)
    .then(() => done())
    .catch((e: Error) => fail(e.message));
}

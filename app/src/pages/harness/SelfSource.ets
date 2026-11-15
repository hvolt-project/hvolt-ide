// The IDE's own source, unpacked where it can be edited.
//
// The source ships inside the bundle as one archive: 52 .ets files plus the resources they need,
// 2.5 MB compressed. Inside the bundle it is read-only, so the first run copies it into the sandbox
// and unpacks it there — from then on it is an ordinary hvolt project that can be opened, edited,
// built, and pushed back over the app that is running it.

import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import zlib from '@ohos.zlib';
import util from '@ohos.util';
import { SELF_PROJECT } from '../model/Project';

const ARCHIVE: string = 'self/source.zip';
/**
 * Where the archive unpacks: straight into the project stage, under a fixed name, so the IDE's own
 * source is an ordinary entry in the project list — openable, editable, buildable — rather than
 * something only the code knows about.
 *
 * The name does not carry a version: it is one project that gets replaced, not a series that piles
 * up. Whether the unpacked tree is current is decided by the stamp below.
 */
const ROOT: string = 'stage/' + SELF_PROJECT;

/**
 * Bumped whenever the shipped archive changes. Without it a rebuilt archive would keep the previous
 * unpacked tree on every device that had already launched once.
 */
const STAMP: string = '2026-11-15-4';
/** Marker written after a successful unpack. Bump it when the shipped archive changes shape. */
const VERSION: string = '2026-11-15-4';

export class SelfSource {
  private filesDir: string;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  /** Where the editable copy lives. */
  path(): string {
    return this.filesDir + '/' + ROOT;
  }

  /**
   * Removes a directory tree. Only ever used on the unpacked copy, which is regenerated from the
   * bundle — never on anything the person created.
   */
  private removeTree(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      if (fs.statSync(path).isDirectory()) {
        for (const name of fs.listFileSync(path)) {
          this.removeTree(path + '/' + name);
        }
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (e) {
    }
  }

  /**
   * Whether this exact archive has already been unpacked.
   *
   * The marker carries a version rather than just a path: a rebuild that changes what the archive
   * contains has to replace the unpacked tree, otherwise the sandbox keeps an older copy — which is
   * how a version of this file that still carried the keystore would have stayed on the device.
   */
  ready(): boolean {
    try {
      if (!fs.accessSync(this.path() + '/hvolt.toml')) {
        return false;
      }
      const marker = this.path() + '/.source-stamp';
      if (!fs.accessSync(marker)) {
        return false;
      }
      return fs.readTextSync(marker).trim() === STAMP;
    } catch (e) {
      return false;
    }
  }

  /** Copies the bundled archive into the sandbox and unpacks it. Returns the project path. */
  async ensure(): Promise<string> {
    const target = this.path();
    if (this.ready()) {
      return target;
    }
    // A half-unpacked tree from a previous failure must not be mistaken for a complete one: the
    // marker file is what ready() checks, and it is written last.
    // A half-unpacked directory from a previous failure must not be reused: mkdir is idempotent but
    // decompressFile refuses an existing target. Recursive removal is unreliable here, so the old
    // tree is moved aside instead — a rename either works or leaves the path free.
    if (fs.accessSync(target)) {
      const aside = target + '.old-' + Date.now();
      try {
        fs.renameSync(target, aside);
      } catch (e) {
        hilog.warn(0x0000, 'hvoltide', 'self source: could not move stale tree: %{public}s', (e as Error).message);
      }
    }
    const staging = this.filesDir + '/self/work-' + Date.now();
    fs.mkdirSync(staging, true);
    hilog.info(0x0000, 'hvoltide', 'self source: staging %{public}s', staging);
    const archive = staging + '/source.zip';
    const bytes: Uint8Array = await getContext().resourceManager.getRawFileContent(ARCHIVE);
    const file = fs.openSync(archive, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer);
    } finally {
      fs.closeSync(file);
    }
    hilog.info(0x0000, 'hvoltide', 'self source: %{public}d bytes written, decompressing to %{public}s',
      bytes.length, target);
    // Must exist (decompressFile rejects a missing destination) and must be empty (it also rejects
    // files that are already there), which is what moving the previous tree aside achieves.
    fs.mkdirSync(target, true);
    await zlib.decompressFile(archive, target);
    const marker = fs.openSync(target + '/.source-stamp', fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(marker.fd, STAMP);
    } finally {
      fs.closeSync(marker);
    }
    hilog.info(0x0000, 'hvoltide', 'self source: decompress returned');
    if (!fs.accessSync(target + '/hvolt.toml')) {
      // The archive unpacked somewhere unexpected; report it rather than claim success.
      const listed: string[] = [];
      for (const name of fs.listFileSync(target)) {
        listed.push(name);
      }
      throw new Error('source archive did not unpack as expected: ' + listed.join(', '));
    }
    return target;
  }
}

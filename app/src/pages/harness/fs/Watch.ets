// Watching the project for changes made outside this editor.
//
// The reason this exists: once the assistant can write files, the editor's tree and its open
// buffers go stale behind it. Watching the tree means a change lands in the UI without the user
// switching files or pulling to refresh.
//
// inotify events are plain numbers here because the SDK does not export the constants.

import fs from '@ohos.file.fs';

const IN_MODIFY: number = 0x00000002;
const IN_MOVED_TO: number = 0x00000080;
const IN_CREATE: number = 0x00000100;
const IN_DELETE: number = 0x00000200;
const IN_CLOSE_WRITE: number = 0x00000008;
const WATCH_MASK: number = IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_TO;

const MAX_DIRS: number = 64;
const MAX_DEPTH: number = 4;
const DEBOUNCE_MS: number = 400;

export interface WatchEvent {
  path: string;
  created: boolean;
  removed: boolean;
}

/**
 * Watches one directory tree and reports debounced changes.
 *
 * A single watcher cannot see subdirectories, so every directory gets its own; the count is
 * capped because a pathological tree would otherwise open an unbounded number of inotify handles.
 */
export class ProjectWatcher {
  private watchers: fs.Watcher[] = [];
  private timer: number = -1;
  private pending: string[] = [];
  private sink: (events: WatchEvent[]) => void = () => {
  };
  private root: string = '';

  start(root: string, onChanged: (events: WatchEvent[]) => void): void {
    this.stop();
    this.root = root;
    this.sink = onChanged;
    this.attach(root, 0, 0);
  }

  stop(): void {
    for (const watcher of this.watchers) {
      try {
        watcher.stop();
      } catch (e) {
      }
    }
    this.watchers = [];
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.pending = [];
  }

  private attach(dir: string, depth: number, count: number): number {
    if (depth > MAX_DEPTH || count >= MAX_DIRS) {
      return count;
    }
    let opened = count;
    try {
      const watcher = fs.createWatcher(dir, WATCH_MASK, (event: fs.WatchEvent) => {
        if (event.fileName.length === 0) {
          return;
        }
        this.queue(dir + '/' + event.fileName, event.event);
      });
      watcher.start();
      this.watchers.push(watcher);
      opened++;
    } catch (e) {
      return opened;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return opened;
    }
    for (const name of names) {
      if (name.startsWith('.')) {
        continue;
      }
      const full = dir + '/' + name;
      let isDir = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (e) {
        isDir = false;
      }
      if (isDir && opened < MAX_DIRS) {
        opened = this.attach(full, depth + 1, opened);
      }
    }
    return opened;
  }

  /** Collects bursts: a build or a multi-file edit produces many events for one intention. */
  private queue(path: string, mask: number): void {
    this.pending.push(path + '|' + mask);
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      const batch: WatchEvent[] = [];
      const seen: Set<string> = new Set();
      const all: string[] = this.pending;
      this.pending = [];
      for (const entry of all) {
        const cut = entry.lastIndexOf('|');
        const path = entry.substring(0, cut);
        const mask = Number(entry.substring(cut + 1));
        if (seen.has(path)) {
          continue;
        }
        seen.add(path);
        batch.push({
          path: path,
          created: (mask & IN_CREATE) !== 0 || (mask & IN_MOVED_TO) !== 0,
          removed: (mask & IN_DELETE) !== 0
        });
      }
      if (batch.length > 0) {
        this.sink(batch);
      }
    }, DEBOUNCE_MS);
  }
}

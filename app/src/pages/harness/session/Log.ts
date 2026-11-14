// 会话日志的落盘形式：一行一个事件的 JSON，只追加。
//
// 与 dsh-session-persistence-jsonl 一致的两条性质：
//   1. 写入只追加，不改写已有行，崩溃时最多丢掉最后半行；
//   2. **读不懂一行就拒绝重建整份会话**，不静默跳过。跳过一行的代价是 seq 重排：
//      内存里的事件数比文件里的行数少，新事件会占用旧序号，下次保存就把已经写过的
//      内容再写一遍——2026-11-13 的历史重复两遍就是这么来的。
//
// 因此 load() 要么给出一份完整的事件列表，要么给出失败原因，没有第三种结果。

import { KNOWN_EVENT_TYPES } from './Events.ts';
import type { SessionEvent, SessionEventType, SessionSeq, SurfaceOp } from './Events.ts';

/** 读回的结果：要么完整，要么带原因失败。 */
export interface LoadResult {
  ok: boolean;
  events: SessionEvent[];
  /** 失败原因；ok 为 true 时是空串。 */
  reason: string;
  /** 文件里的非空行数，无论成败都给出，用于续写游标。 */
  lines: number;
}

/**
 * 落盘需要的三个动作。设备侧由 ./FsStorage 注入（@ohos.file.fs 的实现）；
 * 纯逻辑测试不注入，日志就只留在内存里——否则测试连 import 都过不去。
 */
export interface LogStorage {
  exists(path: string): boolean;
  read(path: string): string;
  append(path: string, line: string): void;
}

export class SessionLog {
  private readonly path: string;
  private readonly storage: LogStorage | undefined;
  private cache: SessionEvent[] = [];
  private loaded: boolean = false;
  /** 磁盘上已有的非空行数，续写从这里接。 */
  private lines: number = 0;

  constructor(path: string, storage?: LogStorage) {
    this.path = path;
    this.storage = storage;
  }

  /** 有路径又有落盘实现才走磁盘；缺一个就只走内存。 */
  private persistent(): boolean {
    return this.path.length > 0 && this.storage !== undefined;
  }

  /** 读回全部事件。路径为空时没有磁盘内容，视为空日志。 */
  load(): LoadResult {
    this.cache = [];
    this.loaded = true;
    this.lines = 0;
    if (!this.persistent()) {
      return { ok: true, events: this.cache, reason: '', lines: 0 };
    }
    let text = '';
    try {
      const storage = this.storage as LogStorage;
      if (!storage.exists(this.path)) {
        return { ok: true, events: this.cache, reason: '', lines: 0 };
      }
      text = storage.read(this.path);
    } catch (error) {
      return {
        ok: false,
        events: [],
        reason: 'read failed: ' + (error as Error).message,
        lines: 0
      };
    }
    if (text.length === 0) {
      return { ok: true, events: this.cache, reason: '', lines: 0 };
    }

    const parsed: SessionEvent[] = [];
    let seen = 0;
    const rows = text.split('\n');
    for (let index = 0; index < rows.length; index++) {
      const trimmed = rows[index].trim();
      if (trimmed.length === 0) {
        continue;
      }
      seen += 1;
      let event: SessionEvent;
      try {
        event = JSON.parse(trimmed) as SessionEvent;
      } catch (error) {
        return {
          ok: false,
          events: [],
          reason: 'line ' + String(index + 1) + ' is not JSON',
          lines: seen
        };
      }
      if (typeof event.seq !== 'number' || typeof event.type !== 'string') {
        return {
          ok: false,
          events: [],
          reason: 'line ' + String(index + 1) + ' has no seq/type',
          lines: seen
        };
      }
      if (!KNOWN_EVENT_TYPES.has(event.type) && event.ignorable !== true) {
        return {
          ok: false,
          events: [],
          reason: 'line ' + String(index + 1) + ' has unknown type "' + event.type + '"',
          lines: seen
        };
      }
      if (event.seq !== parsed.length) {
        return {
          ok: false,
          events: [],
          reason: 'line ' + String(index + 1) + ' has seq ' + String(event.seq) +
            ', expected ' + String(parsed.length),
          lines: seen
        };
      }
      parsed.push(event);
    }

    this.cache = parsed;
    this.lines = seen;
    return { ok: true, events: this.cache, reason: '', lines: seen };
  }

  /** 用外部读来的事件打底（恢复之后再追加时用）。 */
  seed(events: SessionEvent[]): void {
    this.cache = events.slice();
    this.loaded = true;
    this.lines = events.length;
  }

  /** 已加载的事件快照。 */
  events(): SessionEvent[] {
    if (!this.loaded) {
      this.load();
    }
    return this.cache;
  }

  /** 事件条数，也就是下一个事件的 seq。 */
  /** 是否已经尝试读过磁盘。名字不能叫 loaded：类里已有同名字段，调用会取到布尔值本身。 */
  isLoaded(): boolean {
    return this.loaded;
  }

  length(): number {
    return this.events().length;
  }

  /** 磁盘上已有的行数。 */
  lineCount(): number {
    return this.lines;
  }

  /** 追加一条事件行。路径为空时只在内存里。 */
  write(event: SessionEvent): void {
    if (!this.persistent()) {
      this.cache.push(event);
      this.lines += 1;
      return;
    }
    // 每行自带结尾换行：追加写会把两批内容首尾相接，少了它最后一条与下一条会粘成一行。
    const line = JSON.stringify(event) + '\n';
    (this.storage as LogStorage).append(this.path, line);
    this.cache.push(event);
    this.lines += 1;
  }

  /** 分配 seq 并写入，返回落盘后的事件。seq 取内存条数，与 DSH 的 append 一致。 */
  append(type: SessionEventType, data: Object, surfaceOp?: SurfaceOp,
    sourceEventSeqs?: SessionSeq[]): SessionEvent {
    // 写入侧同样只认已知类型：写进去一条读不回来的事件，等于让下次载入整份拒绝。
    if (!KNOWN_EVENT_TYPES.has(type)) {
      throw new Error('unknown event type "' + type + '"');
    }
    const seq = this.length();
    const base: Record<string, Object> = {
      'type': type,
      'seq': seq,
      'time': Date.now(),
      'data': data
    };
    if (surfaceOp !== undefined) {
      base['surfaceOp'] = surfaceOp;
    }
    if (sourceEventSeqs !== undefined) {
      base['sourceEventSeqs'] = sourceEventSeqs;
    }
    const event = base as SessionEvent;
    this.write(event);
    return event;
  }
}
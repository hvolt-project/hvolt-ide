// 会话日志的读取：一行一个事件。
//
// 关键口径是「坏行只丢尾巴，不作废整份」。这份文件每回合都在追加写，进程被打断是常态，
// 尾行写了一半几乎必然发生；早先的读法遇到这种行就整份判失败，调用方于是把它改名
// .bad-* 并从空会话重开——一次闪退就把整段对话作废，用户看到的是「历史会话加载失效」。

export interface ParsedEvents<T> {
  events: T[];
  /** 因为损坏而没读进来的行数（只可能是末尾连续的那几行）。 */
  dropped: number;
  /** 一行都没读进来：整份不可用。 */
  empty: boolean;
}

interface EventRow {
  seq: number;
  type: string;
}

/** 逐行解析；遇到第一行坏的（半截 JSON、seq 对不上）就停，保留它之前的全部。 */
export function parseSessionEvents<T extends EventRow>(text: string): ParsedEvents<T> {
  const events: T[] = [];
  let dropped = 0;
  const rows: string[] = text.split('\n');
  for (let index = 0; index < rows.length; index += 1) {
    const trimmed = rows[index].trim();
    if (trimmed.length === 0) {
      continue;
    }
    let event: T | null = null;
    try {
      event = JSON.parse(trimmed) as T;
    } catch (error) {
      event = null;
    }
    if (event === null || typeof event.seq !== 'number' || typeof event.type !== 'string' ||
      event.seq !== events.length) {
      // 从这里往后都不再相信：seq 是连续的，断一处后面接不上。
      for (let rest = index; rest < rows.length; rest += 1) {
        if (rows[rest].trim().length > 0) {
          dropped += 1;
        }
      }
      break;
    }
    events.push(event);
  }
  return { events: events, dropped: dropped, empty: events.length === 0 };
}

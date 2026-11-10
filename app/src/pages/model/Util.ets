import { hilog } from '@kit.PerformanceAnalysisKit';

export function lastSegment(path: string): string {
  const parts: string[] = path.split('/');
  return parts[parts.length - 1];
}

// Device-side trace line; also the only place that talks to hilog for the shell.
export function mark(msg: string): void {
  hilog.info(0x0000, 'hvoltide', '%{public}s', msg.substring(0, 400));
}

export const LOG_LIMIT: number = 12000;

// Appending trims from the head: the panel shows the tail, so the head is what can go.
export function withLine(prev: string, line: string): string {
  const next = prev.length === 0 ? line : prev + '\n' + line;
  return next.length > LOG_LIMIT ? next.substring(next.length - LOG_LIMIT) : next;
}

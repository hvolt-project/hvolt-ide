import { hvoltCall } from 'libnavi.so';
import { FILES } from './Stage';
import { mark } from './Util';

export interface HvoltStage {
  id: string;
  ms: number;
  ok: boolean;
}

export interface HvoltArtifact {
  path: string;
  bytes: number;
}

export interface HvoltResult {
  code: number;
  output: string;
  argv: string[];
  stages: HvoltStage[];
  diagnostics: string[];
  artifacts: HvoltArtifact[];
}

// hvolt_run answers with a JSON envelope; everything the shell shows comes from here
// rather than from string sniffing, so a failure is reported as a failure.
export function hvolt(argvJson: string, cwd: string, files: string): HvoltResult {
  const raw = hvoltCall(argvJson, cwd, files);
  // The envelope carries stages, diagnostics and artifacts next to code/output. Logging a
  // head of it is what makes a device-side build diagnosable from `hvolt log` alone.
  mark('envelope:' + raw.substring(0, 600));
  try {
    return JSON.parse(raw) as HvoltResult;
  } catch (e) {
    const fallback: HvoltResult = { code: -1, output: raw };
    return fallback;
  }
}

export function hvoltArgv(parts: string[]): string {
  return JSON.stringify(parts);
}

// The device talks to its own hdcd on the loopback port; the same channel the desktop
// build uses, so the shell needs no host.
export const SELF_HDC: string = '127.0.0.1:8710';

export function deviceLogs(addr: string, bundle: string, tail: number): string {
  const argv = hvoltArgv(['log', '-d', addr, '--bundle', bundle, '--tail', '' + tail]);
  const r = hvolt(argv, FILES, FILES);
  if (r.code !== 0) {
    return 'hilog 读取失败：' + r.output;
  }
  return r.output.length === 0 ? '（无输出）' : r.output;
}

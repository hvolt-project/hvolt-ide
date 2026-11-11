import { FILES } from './Stage';
import { deviceLogs, hvolt, hvoltArgv } from './Hvolt';
import {
  argvBuild, argvConnect, argvDeviceList, argvPush, argvRun, argvStart
} from './Commands';

export interface ActionResult {
  code: number;
  output: string;
  ms: number;
}

function timed(argv: string, cwd: string): ActionResult {
  const t0 = Date.now();
  const r = hvolt(hvoltArgv(JSON.parse(argv) as string[]), cwd, FILES);
  const result: ActionResult = { code: r.code, output: r.output, ms: Date.now() - t0 };
  return result;
}

// hvolt runs inside the app, so each action is one blocking call that already knows
// its outcome; there is no job to poll and nothing to guess.
export function runBuild(proj: string): ActionResult {
  return timed(JSON.stringify(argvBuild()), proj);
}

// Build, sign, install and launch in one command — the toolchain's own self-install
// path, so the shell does not have to keep four steps in sync by hand.
export function runDeploy(proj: string, device: string): ActionResult {
  return timed(JSON.stringify(argvRun(device)), proj);
}

export function runInstall(proj: string, device: string): ActionResult {
  const hap = proj + '/build/entry-signed.hap';
  return timed(JSON.stringify(argvPush(device, hap)), proj);
}

export function runStart(proj: string, device: string, bundle: string): ActionResult {
  return timed(JSON.stringify(argvStart(bundle, device)), proj);
}

// The device reaches its own hdcd over loopback; `device connect` is what registers
// that address as the active install target, and the answer says so in plain words.
export function connectDevice(device: string): ActionResult {
  return timed(JSON.stringify(argvConnect(device)), FILES);
}

// The toolchain already knows which devices it can reach; the sheet shows that list
// instead of keeping its own idea of what is connected.
export function listDevices(): ActionResult {
  return timed(JSON.stringify(argvDeviceList()), FILES);
}

export function whoami(): ActionResult {
  return timed('["agc","whoami"]', FILES);
}

export function agcLogin(): ActionResult {
  return timed('["agc","login"]', FILES);
}

export function readLogs(device: string, bundle: string, tail: number): string {
  return deviceLogs(device, bundle, tail);
}

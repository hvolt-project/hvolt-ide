// argv construction for the toolchain, and the one piece of hvolt.toml read here.
//
// Every command shape below mirrors a call site that already existed; the point is to name it
// once so a flag change does not have to be found by grepping for it. Commands that are never
// issued by the app are deliberately absent.

/** The bundle id declared in hvolt.toml, or the fallback when the file does not declare one. */
export function parseBundle(tomlText: string, fallback: string): string {
  const matched = /bundle\s*=\s*"([^"]*)"/.exec(tomlText);
  return matched === null ? fallback : matched[1];
}

export function argvBuild(): string[] {
  return ['build'];
}

export function argvSign(): string[] {
  return ['sign'];
}

export function argvPush(device: string, hap: string): string[] {
  return ['push', device, '--hap', hap];
}

export function argvRun(device: string): string[] {
  return ['run', device];
}

export function argvStart(bundle: string, device: string): string[] {
  return ['start', bundle + '/EntryAbility', '-d', device];
}

export function argvLog(device: string, bundle: string, tail: number): string[] {
  return ['log', '-d', device, '--bundle', bundle, '--tail', '' + tail];
}

export function argvAbcRecords(abcPath: string): string[] {
  return ['abc-records', abcPath];
}

export function argvConnect(device: string): string[] {
  return ['device', 'connect', device];
}

export function argvDeviceList(): string[] {
  return ['device', 'list'];
}

export function argvAgcWhoami(): string[] {
  return ['agc', 'whoami'];
}

export function argvAgcLogin(): string[] {
  return ['agc', 'login'];
}

export function argvAgcLoginUrl(): string[] {
  return ['agc', 'login', '--print-url'];
}

export function argvAgcLoginWait(port: number): string[] {
  return ['agc', 'login', '--wait', '' + port];
}

export function argvAgcLoginCallback(callbackUrl: string): string[] {
  return ['agc', 'login', '--callback', callbackUrl];
}

export function argvVersion(): string[] {
  return ['--version'];
}

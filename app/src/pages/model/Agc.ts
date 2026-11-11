// AppGallery Connect sign-in: the account state the settings sheet shows, and the two-step
// handshake that fills it.
//
// The login runs on this device: the tool prints an authorization URL and listens on a loopback
// port, so the page can be shown in a WebView while the callback lands here. Extracted from
// Session, which kept the account state, the handshake and the shell's rendering duties in one
// class.

import fs from '@ohos.file.fs';
import { hvoltAsync } from './Connect';
import { FILES } from './Stage';
import { argvAgcLoginCallback, argvAgcLoginUrl, argvAgcLoginWait, argvAgcWhoami } from './Commands';
import { jsonLine, parseAgcUser, parseEnvelope } from './Format';

interface AgcAuthInfo {
  port: number;
  url: string;
}

/** What the account needs from the shell it belongs to. */
export interface AgcHost {
  /** Something the sheet renders has changed. */
  notify: () => void;
  /** A line for the output pane. */
  log: (line: string) => void;
}

export class AgcAccount {
  user: string = '';
  state: string = '查询中';
  /** The authorization URL while a login is waiting for the user. */
  url: string = '';
  private host: AgcHost;

  constructor(host: AgcHost) {
    this.host = host;
  }

  /** Asks the tool who is signed in. The token lives in the sandbox and survives a restart, so
   *  boot reads the account back instead of asking the user to sign in again. */
  refresh(): void {
    this.state = '查询中';
    this.host.notify();
    hvoltAsync(argvAgcWhoami(), FILES, FILES, (raw: string) => {
      const result = parseEnvelope(raw);
      if (result.code === 0) {
        const user = parseAgcUser(result.output);
        this.user = user;
        this.state = user.length > 0 ? '已登录' : '未登录';
      } else {
        this.user = '';
        this.state = '未登录';
      }
      this.host.notify();
    });
  }

  /** Starts the handshake: fetch the URL, show it, then wait on the loopback port. */
  start(): void {
    this.state = '获取授权地址…';
    this.host.notify();
    hvoltAsync(argvAgcLoginUrl(), FILES, FILES, (raw: string) => {
      const result = parseEnvelope(raw);
      // The captured stdout carries other threads' logging, so the object is picked out by
      // its braces rather than parsed off the whole string.
      let port = 0;
      try {
        const info: AgcAuthInfo = JSON.parse(jsonLine(result.output)) as AgcAuthInfo;
        port = info.port;
        this.url = info.url;
        this.state = '等待授权';
      } catch (e) {
        this.state = '获取授权地址失败：' + result.output;
        this.host.notify();
        return;
      }
      this.host.notify();
      hvoltAsync(argvAgcLoginWait(port), FILES, FILES, (done: string) => {
        const finished = parseEnvelope(done);
        this.url = '';
        this.host.log(finished.output.trim());
        this.refresh();
      });
    });
  }

  /** Exchanges the page's callback for a token. */
  complete(callbackUrl: string): void {
    this.url = '';
    this.state = '换取 token…';
    this.host.notify();
    hvoltAsync(argvAgcLoginCallback(callbackUrl), FILES, FILES, (raw: string) => {
      const result = parseEnvelope(raw);
      this.host.log(result.output.trim());
      this.refresh();
    });
  }

  /** Forgets the token. The verdict is read back from the file, so a failed delete still shows. */
  logout(): void {
    try {
      const path = FILES + '/.hvolt/auth.json';
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      this.user = '';
      this.state = '未登录';
    } catch (e) {
      this.state = '登出失败';
    }
    this.host.notify();
  }
}

// ide: a bridge to the live editor surface.
//
// The harness registers its tools before the UI exists, so a tool cannot hold a component
// reference. The page binds its session here once it appears; a call that arrives earlier
// reports "not bound" instead of pretending the editor moved.

import web_webview from '@ohos.web.webview';
import { Session } from './Session';

let boundSession: Session | undefined = undefined;
let boundFlip: ((harness: boolean) => void) | undefined = undefined;

/** Called once from the page: the session that owns the editor, and how to turn the face. */
export function bindIde(session: Session, flipTo: (harness: boolean) => void): void {
  boundSession = session;
  boundFlip = flipTo;
}

export function ideSession(): Session | undefined {
  return boundSession;
}

export function ideController(): web_webview.WebviewController | undefined {
  const session = boundSession;
  return session === undefined ? undefined : session.controller;
}

/** true turns to the harness face, false to the editor face. */
export function ideSwitchFace(harness: boolean): boolean {
  const flip = boundFlip;
  if (flip === undefined) {
    return false;
  }
  flip(harness);
  return true;
}

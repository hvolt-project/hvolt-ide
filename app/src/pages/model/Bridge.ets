import hilog from '@ohos.hilog';

// The page calls into this object through NAPI. Only plain methods live on it: handler
// fields are kept module-level, because a proxy object carrying function-valued properties
// is what took the app down on this device.
let readyHandler: (initial: string) => void = () => {
};
let saveHandler: (text: string) => void = () => {
};
let dirtyHandler: (rel: string, flag: boolean) => void = () => {
};
let posHandler: (line: number, col: number) => void = () => {
};
let chromeHandler: (hidden: boolean) => void = () => {
};
let chatHandler: (dir: number) => void = () => {
};
/** The page asks for a face turn by gesture; the direction is the swipe, and the shell decides
 * which face that lands on. */
export function setChatHandler(handler: (dir: number) => void): void {
  chatHandler = handler;
}

export function setEditorHandlers(
  onReady: (initial: string) => void,
  onSave: (text: string) => void,
  onDirty: (rel: string, flag: boolean) => void,
  onPos: (line: number, col: number) => void,
  onChrome: (hidden: boolean) => void): void {
  readyHandler = onReady;
  saveHandler = onSave;
  dirtyHandler = onDirty;
  posHandler = onPos;
  chromeHandler = onChrome;
}

// Buffer handed to the page when it asks at ready time.
let pendingText: string = '';

export function setPendingText(text: string): void {
  pendingText = text;
}

export class EditorBridge {
  ready(): string {
    const text = pendingText;
    readyHandler(text);
    return text;
  }

  save(text: string): void {
    saveHandler(text);
  }

  // The page knows when its buffer diverges from the file; the tab strip needs that per
  // file, not just for whichever tab happens to be active.
  dirty(rel: string, flag: boolean): void {
    dirtyHandler(rel, flag);
  }

  position(line: number, col: number): void {
    posHandler(line, col);
  }

  chromeHidden(hidden: boolean): void {
    chromeHandler(hidden);
  }

  // The editor cannot turn its own face: the WebView owns the touch stream, so the page
  // reports the finished swipe and lets the shell run the turn. `dir` is the sign of the
  // swipe: negative is a leftward drag, positive rightward.
  openChat(dir: number): void {
    chatHandler(dir);
  }

  // Diagnostics from the page. console.log does not reach hilog here, so the page reports
  // through this instead of silently failing.
  log(text: string): void {
    hilog.info(0x0000, 'hvoltide', 'web: %{public}s', text);
  }
}

export type Bp = 'compact' | 'medium' | 'expanded';

import web_webview from '@ohos.web.webview';
import { writeSource } from './Project';

// The toolchain compiles what is on disk, so unsaved editor text would be silently left
// out of a build. Pull the editor buffer back into the file before building.
export function flushEditor(
  controller: web_webview.WebviewController,
  project: string,
  rel: string,
  report: (line: string) => void,
  onDone?: (written: boolean) => void): void {
  if (rel.length === 0) {
    if (onDone) {
      onDone(false);
    }
    return;
  }
  controller.runJavaScript('hvoltGetText()').then((v: string) => {
    try {
      const text = JSON.parse(v) as string;
      const written = writeSource(project, rel, text);
      if (written) {
        report('flushed ' + rel + ' (' + text.length + ' chars)');
      }
      if (onDone) {
        onDone(written);
      }
    } catch (e) {
      report('flush failed');
      if (onDone) {
        onDone(false);
      }
    }
  }).catch((e: Error) => {
    report('flush: ' + e.message);
    if (onDone) {
      onDone(false);
    }
  });
}

// Monaco renders the file; the shell only pushes text and asks for the buffer back.
export function pushText(
  controller: web_webview.WebviewController,
  text: string,
  rel: string,
  report: (line: string) => void): void {
  const expr = 'window.hvoltRel = ' + JSON.stringify(rel) + '; hvoltSetText(' +
    JSON.stringify(text) + ', "arkts")';
  // The page answers false when Monaco is not up yet; reporting the answer is what tells
  // an empty editor apart from a page that never loaded.
  controller.runJavaScript(expr, (err: Error, result: string) => {
    report('editor:set=' + result + (err ? ' err=' + err.message : ''));
  });
}

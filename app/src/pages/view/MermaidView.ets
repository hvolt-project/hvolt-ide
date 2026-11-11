// Mermaid diagrams render in a WebView because that is the only way to get the real layout
// engine; the library and its host page ship inside the package so it works offline.

import webview from '@ohos.web.webview';
import { palette, Palette } from '../model/Palette';

/** Receives the rendered height from the page so the card can size itself. */
class MermaidBridge {
  onHeight: (height: number) => void = () => {};

  setHeight(height: number): void {
    this.onHeight(height);
  }
}

@Component
export struct MermaidView {
  @Prop dark: boolean = true;
  @Prop code: string = '';
  /** Height in vp, reported by the page and clamped between these bounds. */
  @State private height: number = 88;
  private static readonly MIN_H: number = 88;
  private static readonly MAX_H: number = 260;
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: MermaidBridge = new MermaidBridge();
  private loaded: boolean = false;

  private p(): Palette {
    return palette(this.dark);
  }

  private render(): void {
    if (!this.loaded) {
      return;
    }
    const source = JSON.stringify(this.code);
    const dark = this.dark ? 'true' : 'false';
    try {
      this.controller.runJavaScript('window.renderDiagram(' + source + ', ' + dark + ')');
    } catch (e) {
      // Page not ready yet; onPageEnd will call again.
    }
  }

  aboutToAppear(): void {
    // The page reports device pixels; the layout works in vp. Clamping here keeps a tall diagram
    // from swallowing the transcript and a short one from leaving a hole.
    this.bridge.onHeight = (px: number) => {
      if (px <= 0) {
        return;
      }
      // The page measures in CSS pixels, which already equal vp: cssPx * dpr = devicePx and
      // vp * density = devicePx, with dpr == density. Running px2vp as well scales twice.
      let vp = px;
      if (vp < MermaidView.MIN_H) {
        vp = MermaidView.MIN_H;
      }
      if (vp > MermaidView.MAX_H) {
        vp = MermaidView.MAX_H;
      }
      if (Math.abs(vp - this.height) > 1) {
        this.height = vp;
      }
    };
  }

  build() {
    Column() {
      Web({ src: $rawfile('web/mermaid.html'), controller: this.controller })
        .width('100%')
        .height(this.height)
        .backgroundColor(Color.Transparent)
        .javaScriptAccess(true)
        // Pinch zoom and inner scrolling are for reading a diagram that is larger than its card.
        .zoomAccess(true)
        .javaScriptProxy({
          object: this.bridge,
          name: 'bridge',
          methodList: ['setHeight'],
          controller: this.controller
        })
        .onPageEnd(() => {
          this.loaded = true;
          this.render();
        })
        // A diagram taller than the cap scrolls inside its card instead of stretching the list.
        .nestedScroll({
          scrollForward: NestedScrollMode.SELF_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
    }
    .width('100%')
    .backgroundColor(this.dark ? '#0d1117' : '#f6f8fa')
    .borderRadius(8)
    .clip(true)
  }
}

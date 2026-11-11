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
  @State private height: number = 160;
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
    this.bridge.onHeight = (height: number) => {
      if (height > 0 && Math.abs(height - this.height) > 2) {
        this.height = height;
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
    }
    .width('100%')
    .backgroundColor(this.dark ? '#0d1117' : '#f6f8fa')
    .borderRadius(8)
    .clip(true)
  }
}

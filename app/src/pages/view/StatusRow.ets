// The figures under the transcript, in one place so the editor and the chat cannot drift apart.
//
// Three groups, left to right: how far the session got (turns, steps, rate), what it cost (total
// tokens and the cache share), and how full the context is. Every value is formatted here rather
// than by the caller, because a status row that renders "0.4" in one place and "40%" in another is
// the same numbers telling two different stories.
//
// Nothing is shown when there is nothing to show: a fresh session has no rate and no cache share,
// and printing "0 tok/s · 0%" would read as a fault rather than as "this has not happened yet".

import { palette, Palette } from '../model/Palette';

@Component
export struct StatusRow {
  @Prop dark: boolean = true;
  @Prop turns: number = 0;
  @Prop steps: number = 0;
  /** Decode speed; 0 hides it. */
  @Prop rate: number = 0;
  /** Billed input plus output tokens over the whole session. */
  @Prop totalTokens: number = 0;
  /** Cache share of prompt-side input, 0..100; negative hides it. */
  @Prop cacheHit: number = -1;
  /** Context pressure, 0..100. */
  @Prop pressure: number = 0;
  /** Compact drops the token total and keeps the cache share, as DSH does when space is tight. */
  @Prop compact: boolean = false;

  private p(): Palette {
    return palette(this.dark);
  }

  private kilo(tokens: number): string {
    if (tokens < 1000) {
      return '' + tokens;
    }
    const thousands = tokens / 1000;
    return (thousands >= 100 ? '' + Math.round(thousands) : thousands.toFixed(1)) + 'K';
  }

  private rateText(): string {
    if (this.rate <= 0) {
      return '';
    }
    return (this.rate >= 100 ? '' + Math.round(this.rate) : this.rate.toFixed(1)) + ' tok/s';
  }

  private hitText(): string {
    if (this.cacheHit < 0) {
      return '';
    }
    // One decimal only when rounding to an integer would claim a full hit that did not happen.
    const rounded = Math.round(this.cacheHit);
    if (rounded < 100) {
      return '缓存 ' + rounded + '%';
    }
    return this.cacheHit >= 99.95 ? '缓存 100%' : '缓存 99.9%';
  }

  @Builder
  Figure(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(this.p().textTertiary)
      .maxLines(1)
  }

  @Builder
  Divider() {
    Text('·')
      .fontSize(11)
      .fontColor(this.p().textTertiary)
      .opacity(0.6)
  }

  build() {
    Row({ space: 6 }) {
      // Turns and steps: the two numbers that say where in the session the reader is.
      this.Figure('轮 ' + this.turns)
      this.Divider()
      this.Figure('步 ' + this.steps)
      if (this.rateText().length > 0) {
        this.Divider()
        this.Figure(this.rateText())
      }
      Blank()
      if (!this.compact) {
        this.Figure(this.kilo(this.totalTokens))
        if (this.hitText().length > 0) {
          this.Divider()
        }
      }
      if (this.hitText().length > 0) {
        this.Figure(this.hitText())
      }
      if (this.pressure > 0) {
        this.Divider()
        this.Figure(Math.round(this.pressure) + '%')
      }
    }
    .width('100%')
    .height(20)
    .alignItems(VerticalAlign.Center)
  }
}
// A small markdown renderer for assistant replies.
//
// Scope is deliberate: headings, fenced code, lists, quotes and paragraphs — what a coding
// assistant actually emits. Inline emphasis is stripped rather than styled, because a half-styled
// line reads worse than clean plain text. Anything unrecognised stays as text; nothing is dropped.

import { palette, Palette } from '../model/Palette';

export type MdKind = 'p' | 'h1' | 'h2' | 'h3' | 'code' | 'li' | 'quote';

export interface MdBlock {
  kind: MdKind;
  text: string;
  lang: string;
}

/** Splits markdown into blocks. Fenced blocks swallow everything until their closing fence. */
export function parseMarkdown(source: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines: string[] = source.split('\n');
  let inCode = false;
  let buffer: string[] = [];
  let lang = '';

  const flushParagraph = () => {
    if (buffer.length > 0) {
      blocks.push({ kind: 'p', text: buffer.join('\n'), lang: '' });
      buffer = [];
    }
  };

  for (const raw of lines) {
    const line = raw.replace(/\r$/, '');
    const fence = line.trimStart().startsWith('```');
    if (fence) {
      if (inCode) {
        blocks.push({ kind: 'code', text: buffer.join('\n'), lang: lang });
        buffer = [];
        inCode = false;
        lang = '';
      } else {
        flushParagraph();
        inCode = true;
        lang = line.trim().substring(3).trim();
      }
      continue;
    }
    if (inCode) {
      buffer.push(line);
      continue;
    }
    if (line.trim().length === 0) {
      flushParagraph();
      continue;
    }
    if (line.startsWith('### ')) {
      flushParagraph();
      blocks.push({ kind: 'h3', text: line.substring(4).trim(), lang: '' });
      continue;
    }
    if (line.startsWith('## ')) {
      flushParagraph();
      blocks.push({ kind: 'h2', text: line.substring(3).trim(), lang: '' });
      continue;
    }
    if (line.startsWith('# ')) {
      flushParagraph();
      blocks.push({ kind: 'h1', text: line.substring(2).trim(), lang: '' });
      continue;
    }
    if (line.startsWith('> ')) {
      flushParagraph();
      blocks.push({ kind: 'quote', text: line.substring(2).trim(), lang: '' });
      continue;
    }
    const bullet = line.match(/^\s*[-*]\s+(.*)$/);
    if (bullet !== null) {
      flushParagraph();
      blocks.push({ kind: 'li', text: bullet[1], lang: '' });
      continue;
    }
    buffer.push(line);
  }
  if (inCode && buffer.length > 0) {
    blocks.push({ kind: 'code', text: buffer.join('\n'), lang: lang });
  } else {
    flushParagraph();
  }
  return blocks;
}

/** Drops `code`, **bold** and _italic_ markers: the words stay, the markers do not. */
export function plainInline(text: string): string {
  let out = text;
  out = out.replace(/`([^`]*)`/g, '$1');
  out = out.replace(/\*\*([^*]*)\*\*/g, '$1');
  out = out.replace(/(^|[^*])\*([^*]+)\*/g, '$1$2');
  out = out.replace(/__([^_]*)__/g, '$1');
  return out;
}

@Component
export struct MarkdownView {
  @Prop dark: boolean = true;
  @Prop text: string = '';

  private p(): Palette {
    return palette(this.dark);
  }

  private blockSize(kind: MdKind): number {
    if (kind === 'h1') {
      return 18;
    }
    if (kind === 'h2') {
      return 16;
    }
    if (kind === 'h3') {
      return 15;
    }
    return 14;
  }

  build() {
    Column({ space: 6 }) {
      ForEach(parseMarkdown(this.text), (block: MdBlock, index: number) => {
        if (block.kind === 'code') {
          Text(block.text)
            .fontSize(12)
            .lineHeight(18)
            .fontFamily('monospace')
            .fontColor(this.p().textPrimary)
            .width('100%')
            .padding(10)
            .backgroundColor(this.dark ? '#0d1117' : '#f4f6f8')
            .borderRadius(8)
            .textAlign(TextAlign.Start)
        } else if (block.kind === 'li') {
          Row({ space: 6 }) {
            Text('·')
              .fontSize(14)
              .fontColor(this.p().textTertiary)
            Text(plainInline(block.text))
              .fontSize(14)
              .lineHeight(20)
              .fontColor(this.p().textPrimary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 2 })
        } else if (block.kind === 'quote') {
          Row() {
            Divider()
              .vertical(true)
              .strokeWidth(2)
              .color(this.p().textTertiary)
              .height(18)
              .margin({ right: 8 })
            Text(plainInline(block.text))
              .fontSize(13)
              .lineHeight(19)
              .fontColor(this.p().textSecondary)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else {
          Text(plainInline(block.text))
            .fontSize(this.blockSize(block.kind))
            .lineHeight(block.kind === 'p' ? 21 : (this.blockSize(block.kind) + 8))
            .fontWeight(block.kind === 'p' ? FontWeight.Normal : FontWeight.Medium)
            .fontColor(block.kind === 'p' ? this.p().textPrimary : this.p().textPrimary)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }, (block: MdBlock, index: number) => index + ':' + block.kind + ':' + block.text.length)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// A small markdown renderer for assistant replies.
//
// Scope is deliberate: headings, fenced code with token colours, tables, lists, quotes and
// paragraphs — what a coding assistant actually emits. Anything unrecognised stays as text;
// nothing is dropped.

import { palette, Palette } from '../model/Palette';
import {
  cellWidth, CodeToken, columnWidths, emptyBlock, highlightCode, isTableDivider, MdBlock, MdKind,
  parseMarkdown, plainInline
} from '../model/Markdown';
import { MermaidView } from './MermaidView';

@Component
export struct MarkdownView {
  @Prop dark: boolean = true;
  @Prop text: string = '';

  private p(): Palette {
    return palette(this.dark);
  }

  private tokenColor(kind: string): string {
    const themed = this.dark;
    if (kind === 'keyword') {
      return themed ? '#ff7b72' : '#d73a49';
    }
    if (kind === 'string') {
      return themed ? '#a5d6ff' : '#032f62';
    }
    if (kind === 'number') {
      return themed ? '#79c0ff' : '#005cc5';
    }
    if (kind === 'comment') {
      return themed ? '#8b949e' : '#6a737d';
    }
    return this.p().textPrimary;
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

  @Builder
  CodeBlock(block: MdBlock) {
    Column() {
      if (block.lang.length > 0) {
        Text(block.lang)
          .fontSize(10)
          .fontColor(this.p().textTertiary)
          .width('100%')
          .padding({ left: 10, right: 10, top: 6 })
      }
      // Each line is its own Text so long blocks wrap per line instead of one enormous row.
      ForEach(block.text.split('\n'), (line: string, lineIndex: number) => {
        Text() {
          ForEach(highlightCode(line, block.lang), (token: CodeToken, tokenIndex: number) => {
            Span(token.text)
              .fontColor(this.tokenColor(token.kind))
              .fontFamily('monospace')
              .fontSize(12)
          }, (token: CodeToken, tokenIndex: number) => tokenIndex + ':' + token.kind + ':' + token.text.length)
        }
        .width('100%')
        .padding({ left: 10, right: 10 })
        .fontSize(12)
        .lineHeight(18)
      }, (line: string, lineIndex: number) => lineIndex + ':' + line.length)
    }
    .width('100%')
    .padding({ top: 2, bottom: 8 })
    .backgroundColor(this.dark ? '#0d1117' : '#f4f6f8')
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  private tableWidths: Map<string, number[]> = new Map();

  /** Widths are per table and only depend on its text, so they are computed once per block. */
  private widthsFor(block: MdBlock): number[] {
    const key = block.rows.length + ':' + block.rows.map((row: string[]) => row.join('\u0001')).join('\u0002');
    const cached = this.tableWidths.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const widths = columnWidths(block.rows);
    this.tableWidths.set(key, widths);
    return widths;
  }

  @Builder
  Table(block: MdBlock) {
    // A table is wider than a phone in most real answers, so it scrolls sideways instead of
    // folding every cell into three lines.
    Scroll() {
      Column({ space: 0 }) {
        ForEach(block.rows, (row: string[], rowIndex: number) => {
          Row({ space: 0 }) {
            ForEach(row, (cell: string, cellIndex: number) => {
              Text(plainInline(cell))
                .fontSize(12)
                .lineHeight(17)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontWeight(rowIndex === 0 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(rowIndex === 0 ? this.p().textPrimary : this.p().textSecondary)
                .width(this.widthsFor(block)[cellIndex])
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .textAlign(TextAlign.Start)
            }, (cell: string, cellIndex: number) => cellIndex + ':' + cell.length)
          }
          .alignItems(VerticalAlign.Top)
          .backgroundColor(rowIndex === 0 ? (this.dark ? '#161b22' : '#eef1f4') : Color.Transparent)
          .border({ width: { bottom: 1 }, color: this.dark ? '#21262d' : '#e1e4e8' })
        }, (row: string[], rowIndex: number) => rowIndex + ':' + row.length)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .border({ width: 1, color: this.dark ? '#21262d' : '#e1e4e8' })
    .borderRadius(8)
    .clip(true)
  }

  build() {
    Column({ space: 6 }) {
      ForEach(parseMarkdown(this.text), (block: MdBlock, index: number) => {
        if (block.kind === 'code' && block.lang === 'mermaid') {
          MermaidView({ dark: this.dark, code: block.text })
        } else if (block.kind === 'code') {
          this.CodeBlock(block)
        } else if (block.kind === 'table') {
          this.Table(block)
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
            .fontColor(this.p().textPrimary)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }, (block: MdBlock, index: number) => index + ':' + block.kind + ':' + block.text.length + ':' + block.rows.length)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// A small markdown renderer for assistant replies.
//
// Scope is deliberate: headings, fenced code with token colours, tables, lists, quotes and
// paragraphs — what a coding assistant actually emits. Anything unrecognised stays as text;
// nothing is dropped.

import { palette, Palette } from '../model/Palette';
import { MermaidView } from './MermaidView';

export type MdKind = 'p' | 'h1' | 'h2' | 'h3' | 'code' | 'li' | 'quote' | 'table';

export interface MdBlock {
  kind: MdKind;
  text: string;
  lang: string;
  /** Filled for `table` only: the first row is the header, the rest are body rows. */
  rows: string[][];
}

/** One coloured run of code. Colours are resolved at render time, not here. */
export interface CodeToken {
  text: string;
  kind: string;
}

export function emptyBlock(kind: MdKind, text: string, lang: string): MdBlock {
  return { kind: kind, text: text, lang: lang, rows: [] };
}

/** Rough rendered width of a cell, enough to keep columns aligned without measuring text. */
function cellWidth(text: string): number {
  let wide = 0;
  let narrow = 0;
  for (const ch of text) {
    if (ch.charCodeAt(0) > 0x2e80) {
      wide++;
    } else {
      narrow++;
    }
  }
  const width = wide * 13 + narrow * 7.2 + 18;
  return width < 64 ? 64 : Math.ceil(width);
}

/** Splits a table row `| a | b |` into cells. Escaped pipes are left as text. */
function splitRow(line: string): string[] {
  let body = line.trim();
  if (body.startsWith('|')) {
    body = body.substring(1);
  }
  if (body.endsWith('|')) {
    body = body.substring(0, body.length - 1);
  }
  const cells: string[] = [];
  for (const cell of body.split('|')) {
    cells.push(cell.trim());
  }
  return cells;
}

/** A separator row is `|---|---|` with optional alignment colons. */
function isTableDivider(line: string): boolean {
  const trimmed = line.trim();
  if (trimmed.length === 0 || !trimmed.startsWith('|')) {
    return false;
  }
  for (const ch of trimmed) {
    if (ch !== '|' && ch !== '-' && ch !== ':' && ch !== ' ' && ch !== '\t') {
      return false;
    }
  }
  return trimmed.indexOf('-') >= 0;
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
      blocks.push(emptyBlock('p', buffer.join('\n'), ''));
      buffer = [];
    }
  };

  let index = 0;
  while (index < lines.length) {
    const line = lines[index].replace(/\r$/, '');
    index++;

    const fence = line.trimStart().startsWith('```');
    if (fence) {
      if (inCode) {
        blocks.push(emptyBlock('code', buffer.join('\n'), lang));
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

    // A table starts with a pipe row whose next line is a divider.
    if (line.trim().startsWith('|') && index < lines.length && isTableDivider(lines[index].replace(/\r$/, ''))) {
      flushParagraph();
      const rows: string[][] = [splitRow(line)];
      index++;
      while (index < lines.length) {
        const next = lines[index].replace(/\r$/, '');
        if (!next.trim().startsWith('|')) {
          break;
        }
        rows.push(splitRow(next));
        index++;
      }
      blocks.push({ kind: 'table', text: '', lang: '', rows: rows });
      continue;
    }

    if (line.startsWith('### ')) {
      flushParagraph();
      blocks.push(emptyBlock('h3', line.substring(4).trim(), ''));
      continue;
    }
    if (line.startsWith('## ')) {
      flushParagraph();
      blocks.push(emptyBlock('h2', line.substring(3).trim(), ''));
      continue;
    }
    if (line.startsWith('# ')) {
      flushParagraph();
      blocks.push(emptyBlock('h1', line.substring(2).trim(), ''));
      continue;
    }
    if (line.startsWith('> ')) {
      flushParagraph();
      blocks.push(emptyBlock('quote', line.substring(2).trim(), ''));
      continue;
    }
    const bullet = line.match(/^\s*[-*]\s+(.*)$/);
    if (bullet !== null) {
      flushParagraph();
      blocks.push(emptyBlock('li', bullet[1], ''));
      continue;
    }
    buffer.push(line);
  }
  if (inCode && buffer.length > 0) {
    blocks.push(emptyBlock('code', buffer.join('\n'), lang));
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

const KEYWORDS: string[] = [
  'const', 'let', 'var', 'function', 'return', 'if', 'else', 'for', 'while', 'switch', 'case',
  'break', 'continue', 'class', 'extends', 'implements', 'interface', 'struct', 'enum', 'import',
  'from', 'export', 'default', 'new', 'this', 'super', 'async', 'await', 'try', 'catch', 'finally',
  'throw', 'typeof', 'instanceof', 'in', 'of', 'null', 'undefined', 'true', 'false', 'void', 'fn',
  'pub', 'use', 'mut', 'impl', 'trait', 'match', 'def', 'self', 'lambda', 'with', 'as', 'and',
  'or', 'not', 'pass', 'raise', 'except', 'elif', 'None', 'True', 'False', 'package', 'type',
  'readonly', 'static', 'public', 'private', 'protected', 'get', 'set', 'yield', 'do', 'then'
];

/** Tokenises one code block. Comments and strings are matched first so their contents stay one
 *  run — colouring a `//` inside a string would be wrong more often than right. */
export function highlightCode(code: string, lang: string): CodeToken[] {
  const lineComment = (lang === 'python' || lang === 'bash' || lang === 'sh' || lang === 'yaml')
    ? '#' : '//';
  const tokens: CodeToken[] = [];
  const pattern = new RegExp(
    '(' + (lineComment === '#' ? '#' : '\\/\\/') + '[^\\n]*)' +
    '|(\\/\\*[\\s\\S]*?\\*\\/)' +
    '|("(?:[^"\\\\\\n]|\\\\.)*"|\'(?:[^\'\\\\\\n]|\\\\.)*\'|`(?:[^`\\\\]|\\\\.)*`)' +
    '|(\\b\\d+(?:\\.\\d+)?\\b)' +
    '|([A-Za-z_$][A-Za-z0-9_$]*)' +
    '|([^A-Za-z0-9_$\\s]+)' +
    '|(\\s+)', 'g');

  let last = 0;
  let found = pattern.exec(code);
  while (found !== null) {
    if (found.index > last) {
      tokens.push({ text: code.substring(last, found.index), kind: 'plain' });
    }
    const text = found[0];
    let kind = 'plain';
    if (found[1] !== undefined || found[2] !== undefined) {
      kind = 'comment';
    } else if (found[3] !== undefined) {
      kind = 'string';
    } else if (found[4] !== undefined) {
      kind = 'number';
    } else if (found[5] !== undefined) {
      kind = KEYWORDS.indexOf(text) >= 0 ? 'keyword' : 'plain';
    }
    tokens.push({ text: text, kind: kind });
    last = found.index + text.length;
    if (text.length === 0) {
      break;
    }
    found = pattern.exec(code);
  }
  if (last < code.length) {
    tokens.push({ text: code.substring(last), kind: 'plain' });
  }
  return tokens;
}

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

  /** Widest cell per column, so every row lines up without wrapping. */
  private columnWidths(rows: string[][]): number[] {
    const widths: number[] = [];
    for (const row of rows) {
      for (let index = 0; index < row.length; index++) {
        const width = cellWidth(plainInline(row[index]));
        if (index >= widths.length) {
          widths.push(width);
        } else if (width > widths[index]) {
          widths[index] = width;
        }
      }
    }
    return widths;
  }

  private tableWidths: Map<string, number[]> = new Map();

  /** Widths are per table and only depend on its text, so they are computed once per block. */
  private widthsFor(block: MdBlock): number[] {
    const key = block.rows.length + ':' + block.rows.map((row: string[]) => row.join('\u0001')).join('\u0002');
    const cached = this.tableWidths.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const widths = this.columnWidths(block.rows);
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

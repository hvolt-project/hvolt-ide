// Markdown parsing for assistant replies: blocks, tables, inline markers and code tokens.
//
// This file holds no ArkUI code on purpose. It runs under the device build and, unchanged, under
// Node's type stripping, so the parser has tests instead of only on-device observation.

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

/** Splits a table row `| a | b |` into cells. */
export function splitRow(line: string): string[] {
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
export function isTableDivider(line: string): boolean {
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
    if (line.trim().startsWith('|') && index < lines.length &&
        isTableDivider(lines[index].replace(/\r$/, ''))) {
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

/** Rough rendered width of a cell, enough to keep columns aligned without measuring text. */
export function cellWidth(text: string): number {
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

/** Widest cell per column, so every row lines up without wrapping. */
export function columnWidths(rows: string[][]): number[] {
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
  const hashComment = (lang === 'python' || lang === 'bash' || lang === 'sh' || lang === 'yaml');
  const tokens: CodeToken[] = [];
  const pattern = new RegExp(
    '(' + (hashComment ? '#' : '\\/\\/') + '[^\\n]*)' +
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

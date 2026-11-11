// Tests for the markdown parser. Run with: node --test test/
//
// The parser is pure and lives in a .ts module precisely so these run without a device: every
// fix to rendering so far was verified by looking at a phone, which is how a missing helper and a
// dropped field both reached the device before anyone noticed.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  cellWidth, columnWidths, emptyBlock, highlightCode, isTableDivider, parseMarkdown, plainInline,
  splitRow
} from '../app/src/pages/model/Markdown.ts';

test('a paragraph keeps its lines together', () => {
  const blocks = parseMarkdown('first line\nsecond line');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, 'p');
  assert.equal(blocks[0].text, 'first line\nsecond line');
});

test('a blank line separates paragraphs', () => {
  const blocks = parseMarkdown('one\n\ntwo');
  assert.deepEqual(blocks.map((b) => b.kind), ['p', 'p']);
});

test('headings are graded by hash count', () => {
  const blocks = parseMarkdown('# a\n## b\n### c');
  assert.deepEqual(blocks.map((b) => b.kind), ['h1', 'h2', 'h3']);
  assert.deepEqual(blocks.map((b) => b.text), ['a', 'b', 'c']);
});

test('bullets and quotes are their own block kinds', () => {
  const blocks = parseMarkdown('- item\n> said');
  assert.deepEqual(blocks.map((b) => b.kind), ['li', 'quote']);
  assert.equal(blocks[0].text, 'item');
  assert.equal(blocks[1].text, 'said');
});

test('a fenced block keeps its language and swallows fences inside', () => {
  const blocks = parseMarkdown('```ts\nconst a = 1;\n```');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, 'code');
  assert.equal(blocks[0].lang, 'ts');
  assert.equal(blocks[0].text, 'const a = 1;');
});

test('an unclosed fence still yields the code rather than dropping it', () => {
  const blocks = parseMarkdown('```sh\nls -l');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, 'code');
  assert.equal(blocks[0].text, 'ls -l');
});

test('a pipe table with a divider becomes rows, header first', () => {
  const blocks = parseMarkdown('| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, 'table');
  assert.deepEqual(blocks[0].rows, [['a', 'b'], ['1', '2'], ['3', '4']]);
});

test('a pipe row without a divider stays a paragraph', () => {
  const blocks = parseMarkdown('| not | a table |');
  assert.equal(blocks[0].kind, 'p');
});

test('the table stops at the first non-pipe line', () => {
  const blocks = parseMarkdown('| a |\n|---|\n| 1 |\nafter');
  assert.equal(blocks[0].kind, 'table');
  assert.equal(blocks[0].rows.length, 2);
  assert.equal(blocks[1].kind, 'p');
  assert.equal(blocks[1].text, 'after');
});

test('splitRow trims cells and tolerates missing edge pipes', () => {
  assert.deepEqual(splitRow('| a | b |'), ['a', 'b']);
  assert.deepEqual(splitRow('a | b'), ['a', 'b']);
  assert.deepEqual(splitRow('|  x  |  y  |'), ['x', 'y']);
});

test('isTableDivider accepts alignment colons and rejects content', () => {
  assert.equal(isTableDivider('|---|---|'), true);
  assert.equal(isTableDivider('|:--|--:|'), true);
  assert.equal(isTableDivider('| a | b |'), false);
  assert.equal(isTableDivider('---'), false);
});

test('plainInline drops markers but keeps the words', () => {
  assert.equal(plainInline('use `code` here'), 'use code here');
  assert.equal(plainInline('**bold** and __also__'), 'bold and also');
  assert.equal(plainInline('*italic*'), 'italic');
});

test('cellWidth grows with content and never collapses', () => {
  // Short cells all land on the 64pt floor, which is the point: a narrow column still needs room.
  assert.equal(cellWidth(''), 64);
  assert.equal(cellWidth('ab'), 64);
  assert.ok(cellWidth('a much longer cell') > 64);
  assert.ok(cellWidth('这是一个很长的中文单元格内容') > 64);
});

test('columnWidths takes the widest cell per column', () => {
  const widths = columnWidths([['a', 'bb'], ['a much longer cell', 'b']]);
  assert.equal(widths.length, 2);
  assert.ok(widths[0] > widths[1]);
});

test('highlights keywords, numbers, strings and comments', () => {
  const tokens = highlightCode('const n = 42; // note', 'ts');
  const kinds = tokens.map((t) => t.kind);
  assert.ok(kinds.includes('keyword'));
  assert.ok(kinds.includes('number'));
  assert.ok(kinds.includes('comment'));
  const keyword = tokens.find((t) => t.kind === 'keyword');
  assert.equal(keyword?.text, 'const');
});

test('a // inside a string is not treated as a comment', () => {
  const tokens = highlightCode('const url = "https://example.com";', 'ts');
  const strings = tokens.filter((t) => t.kind === 'string');
  assert.equal(strings.length, 1);
  assert.equal(strings[0].text, '"https://example.com"');
  assert.equal(tokens.filter((t) => t.kind === 'comment').length, 0);
});

test('hash is a comment marker only in the languages that use it', () => {
  const python = highlightCode('# a note', 'python');
  assert.equal(python[0].kind, 'comment');
  const ts = highlightCode('# a note', 'ts');
  assert.notEqual(ts[0].kind, 'comment');
});

test('highlighting never loses characters', () => {
  const code = 'function f(a) {\n  return "x" + 1; // ok\n}';
  const joined = highlightCode(code, 'ts').map((t) => t.text).join('');
  assert.equal(joined, code);
});

test('emptyBlock reports no table rows', () => {
  const block = emptyBlock('p', 'x', '');
  assert.deepEqual(block.rows, []);
  assert.equal(block.kind, 'p');
});

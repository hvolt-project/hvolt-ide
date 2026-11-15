// Tests for one event line: the collapsed title, the expanded body, the identity key and the
// foldable predicate.
//
// These used to be untestable because the module was `.ets`, which Node cannot load — the only
// way to "test" them was to copy the logic into a script, and a copy proves nothing about the
// shipped code. They now live in `model/Lines.ts` so the real functions run here.

import test from 'node:test';
import assert from 'node:assert/strict';

import { foldable, lineDetail, lineTitle, makeLine } from '../app/src/pages/model/Lines.ts';
import type { ChatKind, ChatLine } from '../app/src/pages/model/Lines.ts';

function line(kind: ChatKind, text: string, name = ''): ChatLine {
  return makeLine(kind, text, name);
}

// ── title ────────────────────────────────────────────────────────────────────────────────

test('a thought title carries its first line, so the row says something', () => {
  assert.equal(lineTitle(line('thought', '先看数据层\n再看渲染')), '思考 · 先看数据层');
});

test('the ** markers are stripped from a thought summary', () => {
  assert.equal(lineTitle(line('thought', '**结论**：分歧在缓存')), '思考 · 结论：分歧在缓存');
});

test('an empty thought still has a title', () => {
  assert.equal(lineTitle(line('thought', '   ')), '思考');
});

test('a long thought summary is cut at 26 characters with an ellipsis', () => {
  const long = '一'.repeat(40);
  const title = lineTitle(line('thought', long));
  assert.equal(title, '思考 · ' + '一'.repeat(26) + '…');
});

test('a tool title is the tool name plus the first line of its argument', () => {
  assert.equal(lineTitle(line('tool', '{"path":"a.ets"}', 'read')), 'read · {"path":"a.ets"}');
});

test('a tool with no name falls back to a generic noun', () => {
  assert.equal(lineTitle(line('tool', 'args', '')), '工具 · args');
});

test('an ok envelope collapses to just the status, not the whole JSON', () => {
  assert.equal(lineTitle(line('tool', '{"ok":true,"n":3}', 'grep')), 'grep · 完成');
});

test('a failed envelope says so', () => {
  assert.equal(lineTitle(line('tool', '{"ok":false,"error":"boom"}', 'read')), 'read · 失败');
  assert.equal(lineTitle(line('tool', '{"status":"error"}', 'read')), 'read · 失败');
});

test('an injection is titled by its producer', () => {
  assert.equal(lineTitle(line('injection', 'body', 'AGENTS.md')), 'AGENTS.md');
  assert.equal(lineTitle(line('injection', 'body', '')), '上下文');
});

test('a checkpoint is titled by what it replaced', () => {
  assert.equal(lineTitle(line('checkpoint', 'seq 10-40, 12 KB', '压缩点')), '压缩点');
});

test('an error line is titled by its message', () => {
  assert.equal(lineTitle(line('error', 'upstream 502: bad gateway')), 'upstream 502: bad gateway');
});

test('a very long title is cut at 64 characters', () => {
  const long = 'x'.repeat(100);
  assert.equal(lineTitle(line('user', long)), 'x'.repeat(64) + '…');
});

// ── detail ───────────────────────────────────────────────────────────────────────────────

test('the expanded body of a thought or a tool is its full text', () => {
  assert.equal(lineDetail(line('thought', 'line one\nline two')), 'line one\nline two');
  assert.equal(lineDetail(line('tool', '{"a":1}', 'read')), '{"a":1}');
});

test('a checkpoint hides the first line it already showed as a title', () => {
  assert.equal(lineDetail(line('checkpoint', 'seq 10-40\n旧内容摘要', '压缩点')), '旧内容摘要');
});

test('an assistant line has no separate detail — the bubble shows its text', () => {
  assert.equal(lineDetail(line('assistant', 'answer')), '');
});

// An error and an injection used to expand to an empty block — invisible but clickable, and in the
// case of an injection it made the whole foldable declaration a lie. Both now carry their text.
test('an error expands to its text instead of an empty block', () => {
  assert.equal(lineDetail(line('error', 'upstream 502: bad gateway')), 'upstream 502: bad gateway');
});

test('an injection expands to its text instead of an empty block', () => {
  assert.equal(lineDetail(line('injection', 'body text', 'AGENTS.md')), 'body text');
});

// ── foldable ─────────────────────────────────────────────────────────────────────────────

test('process lines fold, content lines do not', () => {
  assert.equal(foldable('thought'), true);
  assert.equal(foldable('tool'), true);
  assert.equal(foldable('injection'), true);
  assert.equal(foldable('checkpoint'), true);
  assert.equal(foldable('user'), false);
  assert.equal(foldable('assistant'), false);
  // An error must stay visible: folding it would hide the reason the turn failed.
  assert.equal(foldable('error'), false);
});

// Identity is no longer derived from content. A content key moved with every streaming delta (the
// length is part of it), so an expanded reasoning row folded itself back on the next token, and two
// identical tool calls collided into one ForEach key. Item identity is positional now — see the
// "group key must not move as the text grows" case in items.test.ts, which pins that.

test('a checkpoint with no producer name is titled by its own first line', () => {
  assert.equal(lineTitle(line('checkpoint', 'seq 10-40\n旧内容', '')), 'seq 10-40');
});

test('a tool with no argument text is just its name', () => {
  assert.equal(lineTitle(line('tool', '', 'read')), 'read');
});

test('an empty injection body still has a title', () => {
  assert.equal(lineTitle(line('injection', '', 'AGENTS.md')), 'AGENTS.md');
});

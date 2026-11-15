// Tests for the transcript rebuild: log messages back into display lines.
//
// This is the path that runs when a session is restored, so a mistake here shows up as "the
// history came back wrong" rather than as a rendering bug. It also pins the event names the
// streaming path uses, which is where a typo silently swallows content.

import test from 'node:test';
import assert from 'node:assert/strict';

import { appendLine, readStats, rebuildLines } from '../app/src/pages/model/ChatView.ts';
import type { ChatMessage, MessageSource, Role } from '../app/src/pages/harness/loop/Types.ts';

function message(role: Role, content: string, source: MessageSource = 'user', reasoning = ''): ChatMessage {
  return {
    id: 0,
    role: role,
    source: source,
    content: content,
    reasoning: reasoning,
    context: '',
    images: []
  };
}

function shape(lines: { kind: string }[]): string[] {
  return lines.map((line: { kind: string }) => line.kind);
}

// ── rebuild ─────────────────────────────────────────────────────────────────────────────

test('a user message becomes a user line', () => {
  const lines = rebuildLines([message('user', '你好')]);
  assert.deepEqual(shape(lines), ['user']);
  assert.equal(lines[0].text, '你好');
});

test('an assistant message keeps its reasoning in front of its text', () => {
  const lines = rebuildLines([message('assistant', '答案', 'model', '先想一下')]);
  assert.deepEqual(shape(lines), ['thought', 'assistant']);
  assert.equal(lines[0].text, '先想一下');
  assert.equal(lines[1].text, '答案');
});

test('an assistant message with only reasoning yields only a thought', () => {
  const lines = rebuildLines([message('assistant', '', 'model', '只有思考')]);
  assert.deepEqual(shape(lines), ['thought']);
});

test('an assistant message with only text yields only the text', () => {
  const lines = rebuildLines([message('assistant', '只有正文', 'model', '')]);
  assert.deepEqual(shape(lines), ['assistant']);
});

test('a tool message becomes a tool line', () => {
  const lines = rebuildLines([message('tool', '{"ok":true}', 'tool')]);
  assert.deepEqual(shape(lines), ['tool']);
});

test('a runtime message becomes an injection line, not a spoken one', () => {
  const lines = rebuildLines([message('user', '运行时上下文', 'runtime')]);
  assert.deepEqual(shape(lines), ['injection']);
  assert.equal(lines[0].name, '上下文');
});

test('a checkpoint message keeps its first line as the title and the rest as the body', () => {
  const lines = rebuildLines([message('user', 'seq 10-40\n旧内容摘要', 'checkpoint')]);
  assert.deepEqual(shape(lines), ['checkpoint']);
  assert.equal(lines[0].name, 'seq 10-40');
  assert.equal(lines[0].text, 'seq 10-40\n旧内容摘要');
});

test('a single-line checkpoint uses the whole text as its title', () => {
  const lines = rebuildLines([message('user', 'seq 1-5', 'checkpoint')]);
  assert.equal(lines[0].name, 'seq 1-5');
});

test('a conversation rebuilds in order', () => {
  const lines = rebuildLines([
    message('user', 'Q1'),
    message('assistant', 'A1', 'model', '想1'),
    message('tool', '{"ok":true}', 'tool'),
    message('user', 'Q2'),
    message('assistant', 'A2', 'model', '')
  ]);
  assert.deepEqual(shape(lines), ['user', 'thought', 'assistant', 'tool', 'user', 'assistant']);
});

test('an empty log rebuilds to nothing', () => {
  assert.deepEqual(rebuildLines([]), []);
});

// ── append ──────────────────────────────────────────────────────────────────────────────

test('consecutive text deltas merge into one line', () => {
  let lines = appendLine([], 'user', 'Q');
  lines = appendLine(lines, 'text', '你');
  lines = appendLine(lines, 'text', '好');
  assert.deepEqual(shape(lines), ['user', 'assistant']);
  assert.equal(lines[1].text, '你好');
});

test('an assistant-named delta is treated as text too', () => {
  let lines = appendLine([], 'text', '前');
  lines = appendLine(lines, 'assistant', '后');
  assert.deepEqual(shape(lines), ['assistant']);
  assert.equal(lines[0].text, '前后');
});

test('the done control event does not blank out the answer', () => {
  // 收尾事件带空正文。早先它落进「未知类型当成正文」这一支，凭空压出一条空 assistant 行，
  // 而 itemsOf 取最后一条 assistant 当答案——于是真答案被折进收起的过程组，正文位置一片空白。
  let lines = appendLine([], 'user', 'Q');
  lines = appendLine(lines, 'text', '这就是答案');
  lines = appendLine(lines, 'done', '');
  assert.deepEqual(shape(lines), ['user', 'assistant']);
  assert.equal(lines[1].text, '这就是答案');
});

test('an unknown event carrying text is still kept as body', () => {
  const lines = appendLine([], 'some-new-kind', '没见过的正文');
  assert.deepEqual(shape(lines), ['assistant']);
  assert.equal(lines[0].text, '没见过的正文');
});

test('consecutive thought deltas merge into one line', () => {
  let lines = appendLine([], 'thought', '想');
  lines = appendLine(lines, 'thought', '更多');
  assert.deepEqual(shape(lines), ['thought']);
  assert.equal(lines[0].text, '想更多');
});

test('a thought arriving after the text is placed in front of it', () => {
  let lines = appendLine([], 'text', '答案');
  lines = appendLine(lines, 'thought', '迟到的思考');
  assert.deepEqual(shape(lines), ['thought', 'assistant']);
});

test('a thought on an empty transcript is simply pushed', () => {
  const lines = appendLine([], 'thought', '想');
  assert.deepEqual(shape(lines), ['thought']);
});

test('a tool delta splits name from arguments', () => {
  const lines = appendLine([], 'tool', 'read {"path":"a.ets"}');
  assert.equal(lines[0].name, 'read');
  assert.equal(lines[0].text, '{"path":"a.ets"}');
});

test('a tool delta without a space is all name', () => {
  const lines = appendLine([], 'tool', 'read');
  assert.equal(lines[0].name, 'read');
  assert.equal(lines[0].text, '');
});

test('a result line borrows the name of the call before it', () => {
  let lines = appendLine([], 'tool', 'read {}');
  lines = appendLine(lines, 'result', '{"ok":true}');
  assert.equal(lines[1].kind, 'tool');
  assert.equal(lines[1].name, 'read');
});

test('a result line with no call before it has no name', () => {
  const lines = appendLine([], 'result', '{"ok":true}');
  assert.equal(lines[0].name, '');
});

test('an error delta becomes an error line', () => {
  const lines = appendLine([], 'error', 'upstream 502');
  assert.deepEqual(shape(lines), ['error']);
});

test('append does not mutate the array it was given', () => {
  const before = appendLine([], 'user', 'Q');
  const after = appendLine(before, 'text', '答');
  assert.equal(before.length, 1);
  assert.equal(after.length, 2);
});
test('text after a tool call is its own line, one line per request', () => {
  // 一次工具调用就是一次独立请求，它前后的正文是两条 assistant message，各自成行；
  // 合成一行会让两段话焊死（中间没有空行）。接成一块是渲染层的事（itemsOf 用空行连）。
  let lines = appendLine([], 'user', 'Q');
  lines = appendLine(lines, 'text', '先看');
  lines = appendLine(lines, 'tool', 'read {}');
  lines = appendLine(lines, 'text', '再看');
  const assistant = lines.filter((line: { kind: string }) => line.kind === 'assistant');
  assert.equal(assistant.length, 2, '一次请求应当自成一段');
  assert.equal(assistant[0].text, '先看');
  assert.equal(assistant[1].text, '再看');
});

test('thought after a tool call is its own line', () => {
  let lines = appendLine([], 'user', 'Q');
  lines = appendLine(lines, 'thought', '想一');
  lines = appendLine(lines, 'tool', 'read {}');
  lines = appendLine(lines, 'thought', '想二');
  const thoughts = lines.filter((line: { kind: string }) => line.kind === 'thought');
  assert.equal(thoughts.length, 2);
});

test('a new turn starts fresh lines', () => {
  let lines = appendLine([], 'user', 'Q1');
  lines = appendLine(lines, 'text', '答一');
  lines = appendLine(lines, 'user', 'Q2');
  lines = appendLine(lines, 'text', '答二');
  const assistant = lines.filter((line: { kind: string }) => line.kind === 'assistant');
  assert.equal(assistant.length, 2, '跨轮的正文被合并了');
});

test('the status bar numbers are optional, not a reason to fail startup', () => {
  const broken = { statsForBar: () => { throw new Error('no stats'); } } as unknown as Parameters<typeof readStats>[0];
  assert.equal(readStats(broken), undefined);
});

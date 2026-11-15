// Tests for the event-sourced session. Run with: node --test test/
//
// 这些断言对的是**当前实现**：append 分配 seq、surface 只收消息类事件、替换靠 surfaceOp
// 而不是删除、JSONL 要么整份读回要么整份拒绝。旧版本这里还断言过 turn 恢复、压缩生命周期
// 与 turn 大纲（closeOpenTail / beginCompaction / turns()），那些能力在当前代码里不存在，
// 断言随feature一起删掉了，不留在套件里假装覆盖。

import test from 'node:test';
import assert from 'node:assert/strict';

import { Session } from '../app/src/pages/harness/session/Session.ts';
import { selectCompactableRange } from '../app/src/pages/harness/session/Compact.ts';
import type { PricedNode } from '../app/src/pages/harness/session/Compact.ts';
import { systemMessage, userMessage, runtimeMessage, assistantMessage } from '../app/src/pages/harness/loop/Types.ts';
import type { ToolCall } from '../app/src/pages/harness/loop/Types.ts';

function call(id: string, name: string): ToolCall {
  return { id: id, name: name, argumentsJson: '{}' };
}

function open(id: string = 'test'): Session {
  return new Session(id, '');
}

test('seq numbers events, not messages', () => {
  const session = open();
  session.append('system/message', { message: systemMessage('s') }, 'append');
  session.append('turn/start', { turn: 0 });
  session.append('user/message', userMessage('hi', '', [], 3), 'append');
  session.append('turn/end', { turn: 0, reason: 'done' });
  assert.deepEqual(session.all().map((event) => event.type),
    ['system/message', 'turn/start', 'user/message', 'turn/end']);
  assert.deepEqual(session.all().map((event) => event.seq), [0, 1, 2, 3]);
});

test('only message events reach the surface', () => {
  const session = open();
  session.append('turn/start', { turn: 0 });
  session.append('tool/call', { turn: 0, step: 0, callId: 'c1', name: 'read', arguments: '{}' });
  session.append('user/message', userMessage('go', '', [], 1), 'append');
  const surface = session.surface().nodes;
  const types = surface.map((seq) => session.all().filter((e) => e.seq === seq)[0].type);
  assert.deepEqual(types, ['user/message'], 'a bare tool/call is bookkeeping, not a message');
});

test('a replacement hides its range without removing anything', () => {
  const session = open();
  session.append('user/message', userMessage('first question', '', [], 0), 'append');
  session.append('assistant/message', { message: assistantMessage('first answer', [], ''), usage: undefined }, 'append');
  const before = session.all().length;
  // 用一个 surface 可承载的消息替换 seq 0..1：日志变长，surface 变短。
  // 替换必须自带 sourceEventSeqs，否则 applySurface 会拒绝（见 Surface.ts）。
  session.append('user/message', userMessage('<compacted-summary> x', '', [], 0),
    { op: 'replace', startSeq: 0, endSeq: 1 }, [0, 1]);
  assert.ok(session.all().length > before, 'the log only grows');
  const visible = session.messages().map((message) => message.content).join('\n');
  assert.ok(visible.includes('<compacted-summary>'));
  assert.ok(!visible.includes('first question'), 'the replaced range left the request');
});

test('the transcript drops the system prompt but keeps runtime injections', () => {
  const session = open();
  session.append('system/message', { message: systemMessage('you are terse') }, 'append');
  session.append('user/message', runtimeMessage('context block'), 'append');
  session.append('user/message', userMessage('real question', '', [], 0), 'append');
  const shown = session.transcript(0).map((message) => message.content).join('\n');
  assert.ok(!shown.includes('you are terse'));
  assert.ok(shown.includes('context block'));
  assert.ok(shown.includes('real question'));
});

test('a recorded tool call and its result show up as a tool message', () => {
  const session = open();
  session.append('turn/start', { turn: 0 });
  session.append('step/start', { turn: 0, step: 0 });
  session.append('assistant/message', {
    message: assistantMessage('', [call('c1', 'read')], ''),
    usage: { uncachedInputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, completionTokens: 0, reasoningTokens: 0, elapsedMs: 0 }
  }, 'append');
  session.noteToolCall(call('c1', 'read'), 1);
  session.appendToolResult('c1', 'file body', false, 2);
  const toolEvents = session.all().filter((event) => event.type === 'tool/call');
  assert.equal(toolEvents.length, 1);
  const result = session.transcript(0).filter((message) => message.role === 'tool');
  assert.equal(result.length, 1);
  assert.equal(result[0].content, 'file body');
  assert.equal(result[0].toolCallId, 'c1');
});

test('the log round-trips through jsonl', () => {
  const session = open();
  session.append('user/message', userMessage('q ' + 'x'.repeat(40), '', [], 0), 'append');
  session.append('assistant/message', { message: assistantMessage('a ' + 'y'.repeat(40), [], ''), usage: undefined }, 'append');
  const text = session.dump();
  const back = open();
  assert.equal(back.load(text), true);
  assert.equal(back.eventCount(), session.eventCount());
  assert.deepEqual(back.messages().map((message) => message.content),
    session.messages().map((message) => message.content));
});

test('a bad line in the middle keeps the prefix instead of voiding the file', () => {
  // 这是「历史会话加载失效」的根因：坏一行就整份判失败、文件改名 .bad-*、从空会话重开，
  // 一次闪退就把整段对话作废。现在只丢坏行及其之后，前面的照读。
  const session = open();
  session.append('user/message', userMessage('q', '', [], 0), 'append');
  session.append('assistant/message', { message: assistantMessage('a', [], ''), usage: undefined }, 'append');
  const lines = session.dump().trim().split('\n');
  lines.splice(1, 0, '{"type":"user/message","seq":99,"data":');
  const back = open();
  assert.equal(back.load(lines.join('\n') + '\n'), true, '坏行不该让整份作废');
  assert.equal(back.eventCount(), 1, '坏行之前的事件要留住');
  assert.equal(back.truncated, 2, '坏行及其之后都算丢弃');
});

test('the compaction range never starts at the system prompt or splits a tool pair', () => {
  const surface = [0, 1, 2, 3];
  const priced: PricedNode[] = [
    { seq: 0, tokens: 10 }, { seq: 1, tokens: 600 }, { seq: 2, tokens: 600 }, { seq: 3, tokens: 10 }
  ];
  const region = selectCompactableRange(surface, priced,
    (seq: number) => seq === 0, () => true, 100);
  assert.notEqual(region, null);
  assert.notEqual(region!.startSeq, 0, 'the system prompt is never replaced');
  if (region !== null) {
    assert.ok(region.endSeq < 3, 'a tail is always retained');
  }
});

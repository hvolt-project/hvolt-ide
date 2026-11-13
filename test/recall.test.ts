// Tests for recall. Run with: node --test test/
//
// Recall is what makes a compiled checkpoint checkable: if a pointer cannot be resolved back to the
// message it names, compaction is lossy no matter how it reads.

import test from 'node:test';
import assert from 'node:assert/strict';

import { hitWindow, parseSeq, readRange, recallEvents, search } from '../app/src/pages/harness/loop/Recall.ts';
import { emptyEvent } from '../app/src/pages/harness/session/Events.ts';
import type { SessionEvent } from '../app/src/pages/harness/session/Events.ts';

function message(seq: number, role: string, content: string, calls: object[] = []): SessionEvent {
  const type = role === 'assistant' ? 'assistant/message' : role === 'tool' ? 'tool/result' : 'user/message';
  const event = emptyEvent(type, seq, 0);
  event.role = role as SessionEvent['role'];
  event.op = 'append';
  event.content = content;
  event.calls = calls as SessionEvent['calls'];
  return event;
}

const LOG: SessionEvent[] = [
  message(1, 'user', '这个内存泄漏查了一下午'),
  message(2, 'assistant', '对象被缓存放进去之后没人释放', [{ id: 'c1', name: 'read', argumentsJson: '{"path":"Loop.ets"}' }]),
  message(3, 'tool', 'file body', []),
  message(4, 'user', '那 chatUrl 呢'),
  message(5, 'assistant', 'chatUrl 移到 Urls.ts 了')
];

test('a single id parses', () => {
  assert.deepEqual(parseSeq('12'), [12, 12]);
});

test('a span parses', () => {
  assert.deepEqual(parseSeq('3-7'), [3, 7]);
});

test('junk does not parse', () => {
  assert.equal(parseSeq(''), null);
  assert.equal(parseSeq('abc'), null);
  assert.equal(parseSeq('7-3'), null);
  assert.deepEqual(parseSeq('0'), [0, 0]);
});

test('a range returns the original bodies', () => {
  const text = readRange(LOG, 1, 2);
  assert.ok(text.includes('[seq 1] user/message: 这个内存泄漏查了一下午'));
  assert.ok(text.includes('[seq 2] assistant/message: 对象被缓存放进去之后没人释放'));
  assert.ok(text.includes('read {"path":"Loop.ets"}'), 'tool calls stay visible');
  assert.ok(!text.includes('chatUrl'), 'the range is respected');
});

test('an empty range says so instead of returning nothing', () => {
  assert.equal(readRange(LOG, 90, 95), 'seq 90-95 没有记录');
});

test('recall with seq resolves it', () => {
  const text = recallEvents(LOG, { seq: '4-5' });
  assert.ok(text.includes('[seq 4] user/message: 那 chatUrl 呢'));
  assert.ok(text.includes('[seq 5] assistant/message: chatUrl 移到 Urls.ts 了'));
});

test('a search finds the ids that mention the word', () => {
  const text = recallEvents(LOG, { query: 'chatUrl' });
  assert.ok(text.includes('[seq 4]'));
  assert.ok(text.includes('[seq 5]'));
  assert.ok(!text.includes('[seq 1]'));
});

test('a search is case-insensitive and quotes the neighbourhood', () => {
  const log: SessionEvent[] = [message(1, 'user', 'prefix CHATURL suffix')];
  const text = recallEvents(log, { query: 'chaturl' });
  assert.ok(text.includes('prefix CHATURL suffix'));
});

test('a search respects the limit', () => {
  const log: SessionEvent[] = [];
  for (let id = 1; id <= 20; id += 1) {
    log.push(message(id, 'user', 'needle in ' + id));
  }
  const text = recallEvents(log, { query: 'needle', limit: 3 });
  assert.equal(text.split('\n').length, 3);
});

test('an empty call explains both modes rather than throwing', () => {
  const text = recallEvents(LOG, {});
  assert.ok(text.includes('seq'));
  assert.ok(text.includes('query'));
});

test('a miss is reported, not silent', () => {
  assert.ok(recallEvents(LOG, { query: 'nowhere' }).includes('没有匹配'));
});

test('the hit window is centred on the match', () => {
  const body = 'a'.repeat(300) + 'NEEDLE' + 'b'.repeat(300);
  const shown = hitWindow(body, 'needle');
  assert.ok(shown.includes('NEEDLE'));
  assert.ok(shown.length < body.length);
  assert.ok(shown.startsWith('…') && shown.endsWith('…'));
});

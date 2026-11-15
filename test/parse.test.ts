
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSessionEvents } from '../app/src/pages/harness/session/Parse.ts';

interface Row {
  seq: number;
  type: string;
  text?: string;
}

const row = (seq: number): string => JSON.stringify({ seq: seq, type: 'assistant/message', text: 'x' + String(seq) });

test('a clean file reads whole', () => {
  const got = parseSessionEvents<Row>([row(0), row(1), row(2)].join('\n'));
  assert.equal(got.events.length, 3);
  assert.equal(got.dropped, 0);
  assert.equal(got.empty, false);
});

test('a half-written tail keeps everything before it', () => {
  // 崩溃时最后一行只写了一半：这是常态，不能因此把整段对话判死。
  const text = [row(0), row(1), '{"seq":2,"type":"assistant/mess'].join('\n');
  const got = parseSessionEvents<Row>(text);
  assert.equal(got.events.length, 2);
  assert.equal(got.dropped, 1);
  assert.equal(got.empty, false);
});

test('a row with a broken sequence stops the read at that point', () => {
  const text = [row(0), row(5), row(6)].join('\n');
  const got = parseSessionEvents<Row>(text);
  assert.equal(got.events.length, 1);
  assert.equal(got.dropped, 2);
});

test('blank lines are skipped, and an all-garbage file is reported empty', () => {
  const blank = '\n\n' + row(0) + '\n\n' + row(1) + '\n';
  assert.equal(parseSessionEvents<Row>(blank).events.length, 2);
  const garbage = parseSessionEvents<Row>('not json at all');
  assert.equal(garbage.empty, true);
  assert.equal(garbage.events.length, 0);
});

// Tests for the text shaping the shell shows: failure lines, turn summaries and the rolling log.

import test from 'node:test';
import assert from 'node:assert/strict';

import { firstLine, jsonLine, mergeTail, parseAgcUser, parseEnvelope, statLine } from '../app/src/pages/model/Format.ts';

function usage(prompt: number, completion: number, reasoning: number): { promptTokens: number; completionTokens: number; totalTokens: number; reasoningTokens: number } {
  return {
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: prompt + completion,
    reasoningTokens: reasoning
  };
}

test('firstLine prefers the line carrying the failure marker', () => {
  const output = 'starting\n\u2717 build failed: missing icon\nnoise';
  assert.equal(firstLine(output), '\u2717 build failed: missing icon');
});

test('firstLine falls back to the first line when nothing failed', () => {
  assert.equal(firstLine('all good\nmore'), 'all good');
});

test('firstLine trims and handles empty input', () => {
  assert.equal(firstLine('   spaced   '), 'spaced');
  assert.equal(firstLine(''), '');
});

test('statLine keeps time first and omits tokens when none were reported', () => {
  assert.equal(statLine(usage(0, 0, 0), 1, 1500), '1.5s');
});

test('statLine includes in/out when tokens were counted', () => {
  const line = statLine(usage(120, 30, 0), 1, 2000);
  assert.equal(line, '2.0s \u00b7 in 120 \u00b7 out 30');
});

test('statLine shows reasoning only when some was spent', () => {
  const line = statLine(usage(100, 20, 15), 1, 1000);
  assert.ok(line.includes('\u601d\u8003 15'));
  assert.ok(!statLine(usage(100, 20, 0), 1, 1000).includes('\u601d\u8003'));
});

test('statLine mentions rounds only past the first', () => {
  assert.ok(!statLine(usage(1, 1, 0), 1, 100).includes('\u8f6e'));
  assert.ok(statLine(usage(1, 1, 0), 3, 100).includes('3 \u8f6e'));
});

test('mergeTail appends and keeps everything under the limit', () => {
  const merged = mergeTail('a\nb', ['c'], 10);
  assert.equal(merged, 'a\nb\nc');
});

test('mergeTail drops the oldest lines past the limit', () => {
  const merged = mergeTail('a\nb\nc', ['d', 'e'], 3);
  assert.equal(merged, 'c\nd\ne');
});

test('mergeTail starts from an empty buffer without a leading blank line', () => {
  assert.equal(mergeTail('', ['x'], 5), 'x');
});

test('mergeTail with a limit of zero yields nothing', () => {
  assert.equal(mergeTail('a\nb', ['c'], 0), '');
});

test('mergeTail trims a single oversized page to the newest lines', () => {
  const page = ['1', '2', '3', '4', '5'];
  assert.equal(mergeTail('', page, 2), '4\n5');
});

test('jsonLine picks the object out of surrounding logging', () => {
  const noisy = 'worker: hello\n{"port":8080,"url":"http://x"}\nnoise';
  assert.equal(jsonLine(noisy), '{"port":8080,"url":"http://x"}');
});

test('jsonLine returns trimmed text when there is no object', () => {
  assert.equal(jsonLine('  plain  '), 'plain');
});

test('jsonLine keeps nested braces inside the outermost pair', () => {
  assert.equal(jsonLine('x {"a":{"b":1}} y'), '{"a":{"b":1}}');
});

test('an envelope yields its code and output', () => {
  const parsed = parseEnvelope('{"code":0,"output":"ok"}');
  assert.equal(parsed.code, 0);
  assert.equal(parsed.output, 'ok');
});

test('a non-JSON answer is a failure carrying the raw text', () => {
  const parsed = parseEnvelope('segmentation fault');
  assert.equal(parsed.code, -1);
  assert.equal(parsed.output, 'segmentation fault');
});

test('a JSON answer without a code is a failure, not a silent success', () => {
  const parsed = parseEnvelope('{"output":"no code"}');
  assert.equal(parsed.code, -1);
  assert.equal(parsed.output, 'no code');
});

test('a JSON answer without an output falls back to the raw text', () => {
  const parsed = parseEnvelope('{"code":2}');
  assert.equal(parsed.code, 2);
  assert.equal(parsed.output, '{"code":2}');
});

test('the AGC user id is read from the whoami answer', () => {
  assert.equal(parseAgcUser('User ID:  70086000195119114\nTeam ID: 1'), '70086000195119114');
});

test('a whoami answer without a user id yields empty', () => {
  assert.equal(parseAgcUser('not logged in'), '');
});

test('a user id that ends the line is still returned', () => {
  assert.equal(parseAgcUser('User ID: abc'), 'abc');
});

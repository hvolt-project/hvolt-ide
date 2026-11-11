// Tests for the text shaping the shell shows: failure lines, turn summaries and the rolling log.

import test from 'node:test';
import assert from 'node:assert/strict';

import { firstLine, mergeTail, statLine } from '../app/src/pages/model/Format.ts';

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

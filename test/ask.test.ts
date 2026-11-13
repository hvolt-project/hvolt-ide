// Tests for the question/answer shapes. Run with: node --test test/
//
// The properties that matter are the ones the model depends on: answers come back identified by
// question id, a multi-select answer keeps every label, free text survives, and a skipped question
// is distinguishable from a declined call.

import test from 'node:test';
import assert from 'node:assert/strict';

import { formatAnswers, formatPending, progressLabel } from '../app/src/pages/model/Ask.ts';
import type { AskAnswer } from '../app/src/pages/model/Ask.ts';

test('one answer carries its question id and labels', () => {
  const answers: AskAnswer[] = [{ id: 'cleanup', selected: ['Yes', 'Also this'], custom: '' }];
  const text = formatAnswers(answers);
  assert.ok(text.startsWith('{"answers":['));
  const parsed = JSON.parse(text);
  assert.deepEqual(parsed.answers[0], { id: 'cleanup', selected: ['Yes', 'Also this'] });
});

test('free text rides along with the selection', () => {
  const text = formatAnswers([{ id: 'a', selected: ['B'], custom: '但把超时改成 120 秒' }]);
  const parsed = JSON.parse(text);
  assert.equal(parsed.answers[0].custom, '但把超时改成 120 秒');
  assert.deepEqual(parsed.answers[0].selected, ['B']);
});

test('a skipped question is an empty selection, not a missing answer', () => {
  const text = formatAnswers([
    { id: 'first', selected: ['x'], custom: '' },
    { id: 'second', selected: [], custom: '' }
  ]);
  const parsed = JSON.parse(text);
  assert.equal(parsed.answers.length, 2);
  assert.deepEqual(parsed.answers[1], { id: 'second', selected: [] });
});

test('several answers keep their order', () => {
  const text = formatAnswers([
    { id: 'q1', selected: ['a'], custom: '' },
    { id: 'q2', selected: ['b'], custom: '' },
    { id: 'q3', selected: [], custom: 'c' }
  ]);
  const parsed = JSON.parse(text);
  assert.deepEqual(parsed.answers.map((a: { id: string }) => a.id), ['q1', 'q2', 'q3']);
});

test('a pending reply names the call so a late answer can be matched', () => {
  const parsed = JSON.parse(formatPending('call-7'));
  assert.equal(parsed.pending, true);
  assert.equal(parsed.callId, 'call-7');
});

test('progress is silent for one question and numbered otherwise', () => {
  assert.equal(progressLabel(0, 1), '');
  assert.equal(progressLabel(0, 3), '1/3');
  assert.equal(progressLabel(2, 3), '3/3');
});

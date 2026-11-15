
import test from 'node:test';
import assert from 'node:assert/strict';
import { composerAction, interruptsTurn } from '../app/src/pages/model/Composer.ts';

test('idle: the key sends', () => {
  assert.equal(composerAction(false, ''), 'send');
  assert.equal(composerAction(false, '有字'), 'send');
});

test('running with an empty draft: the key stops', () => {
  assert.equal(composerAction(true, ''), 'stop');
  // 只有空白也算空：那时按下该停，而不是发一条空消息。
  assert.equal(composerAction(true, '   '), 'stop');
});

test('running with text: the key sends, and sending interrupts', () => {
  assert.equal(composerAction(true, '打断'), 'send');
  assert.equal(interruptsTurn(true), true);
  assert.equal(interruptsTurn(false), false);
});

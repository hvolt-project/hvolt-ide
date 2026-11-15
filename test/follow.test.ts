
import test from 'node:test';
import assert from 'node:assert/strict';
import { FollowBottom } from '../app/src/pages/model/Follow.ts';

test('starts following, and an upward drag stops it right away', () => {
  const f = new FollowBottom();
  assert.equal(f.follows(), true);
  f.onScrollStart();
  // 起手即停：拖动过程中新内容还在到，不能等抬手才判断。
  assert.equal(f.follows(), false);
});

test('releasing at the bottom resumes following; releasing mid-list does not', () => {
  const f = new FollowBottom();
  f.onScrollStart();
  f.onScrollStop(true);
  assert.equal(f.follows(), true);

  f.onScrollStart();
  f.onScrollStop(false);
  assert.equal(f.follows(), false);
});

test('the program’s own scroll never counts as the reader’s', () => {
  const f = new FollowBottom();
  f.beginProgrammatic();
  f.onScrollStart();
  assert.equal(f.follows(), true, '程序自己滚到底不该关掉跟随');
  f.onScrollStop(false);
  assert.equal(f.follows(), true, '程序滚动停下也不该按位置改写跟随');
  f.endProgrammatic();
});

test('a stop without a start (e.g. a resize) leaves the flag alone', () => {
  const f = new FollowBottom();
  f.onScrollStop(false);
  assert.equal(f.follows(), true);
});

test('reset comes back to following', () => {
  const f = new FollowBottom();
  f.onScrollStart();
  f.onScrollStop(false);
  f.reset();
  assert.equal(f.follows(), true);
});

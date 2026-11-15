
// 四档「工作步骤展示」的口径。DSH 的 presentation-policy.js 里 POLICIES 是四张固定表，
// 这里逐项对一遍：档位错了不会报错，只会让某一种模式下该折的不折、该露的藏起来。

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  collapseTimingLabel, collapseTimingOf, presentationPolicyFor,
  TRANSCRIPT_VIEW_MODES, viewModeLabel, viewModeOf
} from '../app/src/pages/model/Policy.ts';

test('compact folds like closed history, but shows no live detail and no preview', () => {
  assert.deepEqual(presentationPolicyFor('compact'), {
    stepGrouping: 'collapsed',
    settledReasoningPreview: false,
    liveProcessDetail: false,
    foldWhileRunning: true,
    collapseTiming: 'immediate'
  });
});

test('standard is compact plus live detail and preview', () => {
  assert.deepEqual(presentationPolicyFor('standard'), {
    stepGrouping: 'collapsed',
    settledReasoningPreview: true,
    liveProcessDetail: true,
    foldWhileRunning: false,
    collapseTiming: 'immediate'
  });
});

test('detailed only folds what has finished', () => {
  assert.deepEqual(presentationPolicyFor('detailed'), {
    stepGrouping: 'history',
    settledReasoningPreview: true,
    liveProcessDetail: true,
    foldWhileRunning: false,
    collapseTiming: 'immediate'
  });
});

test('verbose folds nothing', () => {
  assert.deepEqual(presentationPolicyFor('verbose'), {
    stepGrouping: 'none',
    settledReasoningPreview: true,
    liveProcessDetail: false,
    foldWhileRunning: false,
    collapseTiming: 'immediate'
  });
});

test('every mode has a label, and unknown text degrades to compact', () => {
  assert.deepEqual(TRANSCRIPT_VIEW_MODES, ['compact', 'standard', 'detailed', 'verbose']);
  assert.equal(viewModeLabel('compact'), '精简');
  assert.equal(viewModeLabel('standard'), '标准');
  assert.equal(viewModeLabel('detailed'), '详细');
  assert.equal(viewModeLabel('verbose'), '全部');
  assert.equal(viewModeOf('detailed'), 'detailed');
  assert.equal(viewModeOf('verbose'), 'verbose');
  assert.equal(viewModeOf('standard'), 'standard');
  assert.equal(viewModeOf('看不懂'), 'compact');
});

test('collapse timing: two values, unknown degrades to immediate', () => {
  assert.equal(collapseTimingOf('next-input'), 'next-input');
  assert.equal(collapseTimingOf('immediate'), 'immediate');
  assert.equal(collapseTimingOf('看不懂'), 'immediate');
  assert.equal(collapseTimingLabel('next-input'), '下一条输入时');
  assert.equal(collapseTimingLabel('immediate'), '立即');
});

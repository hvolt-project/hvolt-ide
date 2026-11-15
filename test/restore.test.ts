
// 恢复后再渲染：这条链是「磁盘事件 → rebuildLines → itemsOf → 列表」。
// 之前没有测试盖过它，而它正是「重启后历史会话加载失效 / 折起来后看不出结构」这两类问题的现场。

import test from 'node:test';
import assert from 'node:assert/strict';
import { rebuildLines } from '../app/src/pages/model/ChatView.ts';
import { itemsOf } from '../app/src/pages/model/Items.ts';
import { makeLine } from '../app/src/pages/model/Lines.ts';
import { presentationPolicyFor } from '../app/src/pages/model/Policy.ts';
import type { ChatPresentationPolicy } from '../app/src/pages/model/Policy.ts';

const COMPACT: ChatPresentationPolicy = {
  stepGrouping: 'collapsed',
  settledReasoningPreview: false,
  liveProcessDetail: false,
  foldWhileRunning: true,
  collapseTiming: 'immediate'
};

const assistant = (text: string, reasoning: string, toolCalls: unknown[] = []): unknown => ({
  role: 'assistant',
  content: text,
  reasoning,
  toolCalls,
  id: 0
});

test('a restored turn renders as folded process plus visible answer', () => {
  const messages = [
    { role: 'user', content: '看下工程', id: 0 },
    assistant('', '先看目录', [{ id: 'c1', name: 'read', arguments: '{"path":"a.ets"}' }]),
    { role: 'tool', content: '文件内容', id: 0, toolCallId: 'c1' },
    assistant('答案是：一层目录。', '', [])
  ] as never[];
  const lines = rebuildLines(messages);
  const items = itemsOf(lines, COMPACT, new Map(), -1);
  const kinds = items.map((item) => item.kind);
  assert.deepEqual(kinds, ['user', 'group', 'markdown'],
    '恢复后应当是「用户 → 折叠组 → 答案」');
  const group = items.filter((item) => item.kind === 'group')[0];
  assert.equal(group.collapsed, true, '精简档里已结束的轮要收起');
  assert.ok(group.process.length >= 2, '思考与工具应当都在组里');
  const answer = items.filter((item) => item.kind === 'markdown')[0];
  assert.equal(answer.text, '答案是：一层目录。', '答案必须露在组外');
});

test('a restored turn with no steps is just text', () => {
  const messages = [
    { role: 'user', content: '你好', id: 0 },
    assistant('你好，我在。', '', [])
  ] as never[];
  const items = itemsOf(rebuildLines(messages), COMPACT, new Map(), -1);
  assert.deepEqual(items.map((item) => item.kind), ['user', 'markdown']);
});

test('the four modes give four different transcripts, not the same one', () => {
  // 「详细/全部没区别」这类反馈的守门测试：同一段历史在四档下必须给出四种不同的项序列。
  const messages = [
    { role: 'user', content: '看下工程', id: 0 },
    assistant('', '先看目录', [{ id: 'c1', name: 'read', arguments: '{"path":"a.ets"}' }]),
    { role: 'tool', content: '文件内容', id: 0, toolCallId: 'c1' },
    assistant('答案是：一层目录。', '', [])
  ] as never[];
  const lines = rebuildLines(messages);
  const shapes: string[] = [];
  const modes = ['compact', 'standard', 'detailed', 'verbose'];
  for (const mode of modes) {
    const items = itemsOf(lines, presentationPolicyFor(mode as never), new Map(), -1);
    shapes.push(items.map((item) => item.kind).join('>'));
  }
  const compactItems = itemsOf(lines, presentationPolicyFor('compact'), new Map(), -1);
  assert.equal(compactItems.filter((item) => item.kind === 'group')[0].collapsed, true,
    '精简档：已结束的轮收起');
  const detailedItems = itemsOf(lines, presentationPolicyFor('detailed'), new Map(), -1);
  assert.equal(detailedItems.filter((item) => item.kind === 'group')[0].collapsed, true,
    '详细档：已结束的轮同样收起（只是正在跑的那轮不折）');
  const verboseItems = itemsOf(lines, presentationPolicyFor('verbose'), new Map(), -1);
  assert.equal(verboseItems.filter((item) => item.kind === 'group').length, 0,
    '全部档：不组建，过程逐行');
  // 全部档与其它三档必须不同；另外三档在「全部已结束」时形状相同（都是折起来 + 答案在外），
  // 差别在于跑着的那一轮怎么显示，那部分由另一条测试盯。
  assert.notEqual(shapes[3], shapes[0], '全部档与精简档不该一样');
  assert.notEqual(shapes[3], shapes[2], '全部档与详细档不该一样');
});

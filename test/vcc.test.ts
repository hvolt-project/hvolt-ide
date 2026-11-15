// VCC 确定性压缩的口径测试：分词、密度估计、台账形状与指针。

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  compileCheckpoint, countTokens, estimateDeepSeekTokens, estimateEntryTokens, sanitize, stripNoise
} from '../app/src/pages/harness/session/Vcc.ts';
import type { ChatMessage } from '../app/src/pages/harness/loop/Types.ts';

function message(role: string, content: string, extra: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: 0, role: role as ChatMessage['role'], source: role === 'tool' ? 'tool' : 'model',
    content: content, reasoning: '', context: '', images: [], toolCalls: [], toolCallId: '', ...extra
  };
}

test('word classes count one unit each and whitespace never counts', () => {
  assert.equal(countTokens('read a.ts'), 4, 'read / a / . / ts');
  assert.equal(countTokens('   \n\t '), 0);
  assert.equal(countTokens('12 34'), 2);
});

test('the density estimate follows the documented per-character weights', () => {
  // 10 个非 CJK 字符 → 3 tokens；10 个 CJK 字符 → 6 tokens。
  assert.equal(estimateDeepSeekTokens('abcdefghij'), 3);
  assert.equal(estimateDeepSeekTokens('中文中文中文中文中文'), 6);
  assert.equal(estimateEntryTokens('中文'), Math.max(2, 2));
});

test('sanitize drops carriage returns, ANSI and control bytes only', () => {
  assert.equal(sanitize('a\r\nb'), 'a\nb');
  assert.equal(sanitize('\x1b[31mred\x1b[0m'), 'red');
  assert.equal(sanitize('ok\x07'), 'ok');
});

test('noise wrappers collapse to one marker', () => {
  const body = '前<skill-catalog>很多条目</skill-catalog>后';
  assert.equal(stripNoise(body), '前[catalog]后');
});

test('a checkpoint keeps seq pointers and drops tool result bodies', () => {
  const messages: ChatMessage[] = [
    message('user', '看一下 Loop.ets'),
    message('assistant', '', { toolCalls: [{ id: 'c1', name: 'read', argumentsJson: '{"path":"Loop.ets"}' }] }),
    message('tool', '整个文件正文不该出现', { toolCallId: 'c1' }),
    message('assistant', '结论：那段在 recv 里')
  ];
  const checkpoint = compileCheckpoint({
    seqs: [3, 4, 5, 6], messages: messages, resultSeqs: new Map([['c1', 5]]), turns: 2
  });
  assert.ok(checkpoint.text.startsWith('<checkpoint covers="3-6" turns="2">'));
  assert.ok(checkpoint.text.includes('[seq 3] user: 看一下 Loop.ets'));
  assert.ok(checkpoint.text.includes('[seq 4] assistant: '));
  assert.ok(checkpoint.text.includes('* read Loop.ets (4) -> result 5'), 'the call line carries the pointer');
  assert.ok(!checkpoint.text.includes('整个文件正文不该出现'), 'tool bodies stay out of the ledger');
  assert.ok(checkpoint.text.includes('[seq 6] assistant: 结论'));
  assert.ok(checkpoint.text.endsWith('</checkpoint>'));
  assert.ok(checkpoint.entries >= 3);
});

test('reasoning never enters the ledger and long text is clipped', () => {
  const long: string = 'x'.repeat(600);
  const messages: ChatMessage[] = [
    message('assistant', long, { reasoning: '这段推理不该出现' }),
    message('user', 'y'.repeat(600))
  ];
  const checkpoint = compileCheckpoint({ seqs: [1, 2], messages: messages, resultSeqs: new Map(), turns: 1 });
  assert.ok(!checkpoint.text.includes('这段推理不该出现'));
  const clipped = checkpoint.text.split('\n').filter((line: string) => line.includes('xxxx'));
  assert.ok(clipped.length === 1 && clipped[0].length < 560, 'the body is cut at 400 chars plus the ellipsis');
});

test('a previous checkpoint folds to a single pointer line', () => {
  const messages: ChatMessage[] = [
    message('user', '<checkpoint covers="1-9" turns="3">\n[seq 1] user: 早先的内容\n</checkpoint>'),
    message('user', '新的一轮')
  ];
  const checkpoint = compileCheckpoint({ seqs: [20, 21], messages: messages, resultSeqs: new Map(), turns: 4 });
  assert.ok(checkpoint.text.includes('[seq 20] checkpoint: [checkpoint @ seq 20]'));
  assert.ok(!checkpoint.text.includes('早先的内容'), 'the old body stays one recall away');
  assert.ok(checkpoint.text.includes('[seq 21] user: 新的一轮'));
});

// 会话模型的纯逻辑检查：不碰设备、不碰文件系统，只验 surface 折叠、统计折叠、压缩选区。
// 跑法：node test/session-model.test.ts
//
// 这里不 import node:test 与 node:assert —— hvolt 会把本文件当作源一并编译，看到 node: 前缀就
// 要求声明依赖。自带几个断言函数就够用。

import { applySurface, emptySurface } from '../src/pages/harness/session/Surface.ts';
import { selectCompactableRange } from '../src/pages/harness/session/Compact.ts';

let passed = 0;
const failures: string[] = [];

function fail(name: string, detail: string): void {
  failures.push(name + ': ' + detail);
}

function same(name: string, actual: string, expected: string): void {
  if (actual === expected) {
    passed += 1;
    return;
  }
  fail(name, 'expected ' + expected + ', got ' + actual);
}

function list(name: string, actual: number[], expected: number[]): void {
  const a = actual.join(',');
  const e = expected.join(',');
  if (a === e) {
    passed += 1;
    return;
  }
  fail(name, 'expected [' + e + '], got [' + a + ']');
}

function throws(name: string, run: () => void, marker: string): void {
  try {
    run();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.indexOf(marker) >= 0) {
      passed += 1;
      return;
    }
    fail(name, 'threw "' + message + '", wanted it to mention "' + marker + '"');
    return;
  }
  fail(name, 'did not throw');
}

function event(seq: number, type: string, data: object, extra: object = {}): any {
  return { seq, type, time: 1000 + seq, data, ...extra };
}

// --- surface ------------------------------------------------------------------------------------

{
  let state = emptySurface();
  state = applySurface(state, event(0, 'user/message', { role: 'user' }, { surfaceOp: 'append' }));
  state = applySurface(state, event(1, 'assistant/message', { role: 'assistant' }, { surfaceOp: 'append' }));
  list('surface: append 放到尾部', state.nodes, [0, 1]);
}

{
  let state = emptySurface();
  state = applySurface(state, event(0, 'user/message', {}, { surfaceOp: 'append' }));
  state = applySurface(state, event(1, 'assistant/message', {}, { surfaceOp: 'append' }));
  state = applySurface(state, event(2, 'user/message', {}, { surfaceOp: 'append' }));
  state = applySurface(state, event(3, 'user/message', {},
    { surfaceOp: { op: 'replace', startSeq: 0, endSeq: 1 }, sourceEventSeqs: [0, 1] }));
  list('surface: replace 遮蔽区间并占位', state.nodes, [3, 2]);
  same('surface: replace 记一次替换', String(state.replaceGeneration), '1');
}

{
  let state = emptySurface();
  state = applySurface(state, event(0, 'user/message', {}, { surfaceOp: 'append' }));
  state = applySurface(state, event(1, 'user/message', {}, { surfaceOp: 'append' }));
  throws('surface: 漏掉被遮蔽节点要报错', () => {
    applySurface(state, event(2, 'user/message', {},
      { surfaceOp: { op: 'replace', startSeq: 0, endSeq: 1 }, sourceEventSeqs: [0] }));
  }, 'must include every shadowed surface node');
}

// --- compaction ---------------------------------------------------------------------------------

{
  const seqs = [0, 1, 2, 3, 4];
  const priced = [
    { seq: 0, tokens: 100 }, { seq: 1, tokens: 100 }, { seq: 2, tokens: 100 },
    { seq: 3, tokens: 100 }, { seq: 4, tokens: 100 },
  ];
  const region = selectCompactableRange(seqs, priced, (seq: number) => seq === 0,
    () => true, 250);
  // 尾部 3 个节点共 300 tokens 已够保留预算 250，保留起点是 index 2，被压掉的只有 index 1。
  same('compact: system 头不进区间', String(region === null ? 'null' : region.startSeq + '-' + region.endSeq), '1-1');
}

{
  const seqs = [0, 1];
  const priced = [{ seq: 0, tokens: 10 }, { seq: 1, tokens: 10 }];
  const region = selectCompactableRange(seqs, priced, () => false, () => false, 5);
  same('compact: 配对失衡且无处可退返回 null', String(region), 'null');
}

if (failures.length > 0) {
  for (const line of failures) {
    console.log('✗ ' + line);
  }
  console.log(String(passed) + ' passed, ' + String(failures.length) + ' failed');
  throw new Error('failed');
}
console.log(String(passed) + ' passed, 0 failed');
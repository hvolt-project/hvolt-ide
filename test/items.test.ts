// Tests for the transcript item builder: what a run of lines becomes on screen.
//
// Driven the way the panel drives it — a line array grows delta by delta, and the items are
// rebuilt after every delta — because the failure this catches is not "the formula is wrong" but
// "the formula is right and the view never re-ran it".
//
// Only the public behaviour is asserted (item kinds, order, collapse state, group wording). The
// helper functions behind it are free to be renamed or merged.

import test from 'node:test';
import assert from 'node:assert/strict';

import { activityOfTool, itemDigest, itemsOf, memberStyle, planItems } from '../app/src/pages/model/Items.ts';
import type { StreamItem } from '../app/src/pages/model/Items.ts';
import { foldable, lineDetail, lineTitle, makeLine } from '../app/src/pages/model/Lines.ts';
import type { ChatLine } from '../app/src/pages/model/Lines.ts';
import { appendLine } from '../app/src/pages/model/ChatView.ts';
import type { ChatPresentationPolicy, StepGrouping } from '../app/src/pages/model/Policy.ts';

function policy(grouping: StepGrouping = 'collapsed', timing = 'immediate' as 'immediate' | 'next-input', preview = false, liveDetail = false): ChatPresentationPolicy {
  return {
    stepGrouping: grouping,
    settledReasoningPreview: preview,
    liveProcessDetail: liveDetail,
    foldWhileRunning: false,
    collapseTiming: timing
  };
}

/** The subset of the item that the assertions care about. */
function shape(items: { kind: string }[]): string[] {
  return items.map((item: { kind: string }) => item.kind);
}

function kinds(items: { kind: string }[], kind: string): number {
  return items.filter((item: { kind: string }) => item.kind === kind).length;
}

// ── a growing stream ────────────────────────────────────────────────────────────────────

/** Append a delta the way the transport callback does: extend the tail if it fits, else new line. */
function feed(lines: ChatLine[], kind: 'thought' | 'tool' | 'assistant', text: string, name = ''): void {
  const tail = lines[lines.length - 1];
  if (tail !== undefined && tail.kind === kind && name === '') {
    tail.text += text;
    return;
  }
  lines.push(makeLine(kind, text, name));
}

const RUNNING = 0;

test('a thought delta opens a group, and the group stays open while the turn runs', () => {
  const lines: ChatLine[] = [makeLine('user', '看下代码', '')];
  feed(lines, 'thought', '先看看');
  const first = itemsOf(lines, policy(), new Map(), RUNNING);
  assert.deepEqual(shape(first), ['user', 'group']);
  assert.equal(first[1].collapsed, false);
  assert.equal(first[1].title, '正在分析请求');

  feed(lines, 'thought', '数据层');
  const second = itemsOf(lines, policy(), new Map(), RUNNING);
  assert.deepEqual(shape(second), ['user', 'group']);
  assert.equal(second[1].collapsed, false);
  // The group key must not move as the text grows, or LazyForEach rebuilds the row every delta.
  assert.equal(second[1].key, first[1].key);
});

test('a tool delta joins the same group instead of adding a row', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', '')];
  feed(lines, 'thought', '想');
  feed(lines, 'tool', '{"path":"a.ets"}', 'read');
  const items = itemsOf(lines, policy(), new Map(), RUNNING);
  assert.deepEqual(shape(items), ['user', 'group']);
  assert.equal(items[1].process.length, 2);
  // The header speaks both activities, in order.
  assert.equal(items[1].title, '正在分析请求并正在读取文件');
});

test('the first content delta puts a markdown item after the group', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', '')];
  feed(lines, 'thought', '想');
  feed(lines, 'tool', '{}', 'read');
  feed(lines, 'assistant', '我看');
  feed(lines, 'assistant', '到了。');
  const items = itemsOf(lines, policy(), new Map(), RUNNING);
  // 整轮都在组里（答案也是成员）：DSH 的 foldable 就是「这一轮有东西可折」。
  assert.deepEqual(shape(items), ['user', 'group', 'markdown']);
  assert.equal(items[2].text, '我看到了。');
  // Still running: the group must not fold under the reader.
  assert.equal(items[1].collapsed, false);
});

test('the group folds once the turn ends', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''),
    makeLine('thought', '想', ''),
    makeLine('assistant', '答', '')
  ];
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.equal(items[1].collapsed, true);
  assert.equal(items[1].title, '已完成分析');
});

test('a second turn does not fold the first turn\'s group over again', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q1', ''), makeLine('thought', '想1', ''), makeLine('assistant', 'A1', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', '想2', '')
  ];
  const items = itemsOf(lines, policy(), new Map(), 3);
  const groups = items.filter((item: { kind: string }) => item.kind === 'group');
  assert.equal(groups.length, 2);
  assert.equal(groups[0].collapsed, true);
  assert.equal(groups[1].collapsed, false);
  // 第二轮还在跑，没有答案块；第一轮的答案在组外，所以只有一块正文。
  assert.equal(kinds(items, 'markdown'), 1);
});

// ── manual open ─────────────────────────────────────────────────────────────────────────

test('a group opened by hand overrides the fold', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const closed = itemsOf(lines, policy(), new Map(), -1);
  const key = closed[1].key;
  const opened = itemsOf(lines, policy(), new Map([[key, true]]), -1);
  assert.equal(opened[1].collapsed, false);
});

test('opening one group leaves the others alone', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q1', ''), makeLine('thought', 'a', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', 'b', '')
  ];
  const base = itemsOf(lines, policy(), new Map(), -1);
  const firstKey = base.filter((item: { kind: string }) => item.kind === 'group')[0].key;
  const items = itemsOf(lines, policy(), new Map([[firstKey, true]]), -1);
  const groups = items.filter((item: { kind: string }) => item.kind === 'group');
  assert.equal(groups[0].collapsed, false);
  assert.equal(groups[1].collapsed, true);
});

// ── collapse timing ─────────────────────────────────────────────────────────────────────

test('next-input keeps the last finished group open until the next turn arrives', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const items = itemsOf(lines, policy('collapsed', 'next-input'), new Map(), -1);
  assert.equal(items[1].collapsed, false);
});

test('next-input only spares the newest group, not every finished one', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q1', ''), makeLine('thought', 'a', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', 'b', '')
  ];
  const items = itemsOf(lines, policy('collapsed', 'next-input'), new Map(), -1);
  const groups = items.filter((item: { kind: string }) => item.kind === 'group');
  assert.equal(groups[0].collapsed, true);
  assert.equal(groups[1].collapsed, false);
});

// ── errors ──────────────────────────────────────────────────────────────────────────────

test('an error keeps its group open and is never folded away', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('error', 'upstream 502', '')
  ];
  const items = itemsOf(lines, policy(), new Map(), -1);
  const group = items.filter((item: { kind: string }) => item.kind === 'group')[0];
  assert.equal(group.collapsed, false);
  const error = items.filter((item: { kind: string }) => item.kind === 'error')[0];
  assert.equal(error.collapsed, false);
  assert.equal(error.title, 'upstream 502');
});

// ── view modes ──────────────────────────────────────────────────────────────────────────

test('collapsed mode groups and hides reasoning from the stream', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{}', 'read'), makeLine('assistant', '答', '')
  ];
  const items = itemsOf(lines, policy('collapsed'), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'group', 'markdown']);
  assert.equal(kinds(items, 'reasoning'), 0);
  assert.equal(kinds(items, 'tool'), 0);
});

test('none mode inlines every process line in order', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{}', 'read'), makeLine('assistant', '答', '')
  ];
  const items = itemsOf(lines, policy('none'), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'reasoning', 'tool', 'markdown']);
});

test('history mode groups only what has finished, and inlines the live turn', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q1', ''), makeLine('thought', 'a', ''), makeLine('assistant', 'A1', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', 'b', '')
  ];
  const items = itemsOf(lines, policy('history'), new Map(), 3);
  // 已结束的第一轮：过程折成一项，答案在组外；运行中的第二轮逐行内联。
  assert.deepEqual(shape(items), ['user', 'group', 'markdown', 'user', 'reasoning']);
});

// ── header wording ─────────────────────────────────────────────────────────────────────

test('two activities are joined with 并, three or more end with 等', () => {
  const two: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('tool', '{}', 'read')];
  assert.equal(itemsOf(two, policy(), new Map(), -1)[1].title, '已完成分析并已读取文件');

  const many: ChatLine[] = [
    makeLine('user', 'Q', ''),
    makeLine('thought', '想', ''),
    makeLine('tool', '{}', 'read'),
    makeLine('tool', '{}', 'shell'),
    makeLine('tool', '{}', 'web_search')
  ];
  assert.equal(
    itemsOf(many, policy(), new Map(), -1)[1].title,
    '已完成分析、已读取文件、执行了命令等'
  );
});

test('a group with no process lines has no header at all', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('assistant', '答', '')];
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'markdown']);
});

test('the group activity is the last tool it ran, which picks the icon', () => {
  const withRead: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('tool', '{}', 'read'), makeLine('tool', '{}', 'grep')
  ];
  assert.equal(itemsOf(withRead, policy(), new Map(), -1)[1].activity, 'search');

  const thoughtOnly: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  assert.equal(itemsOf(thoughtOnly, policy(), new Map(), -1)[1].activity, 'thinking');
});

test('an unknown tool name still lands in a known activity', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('tool', '{}', 'mystery_tool')];
  assert.equal(itemsOf(lines, policy(), new Map(), -1)[1].activity, 'tools');
});

// A tool named like a substring of another must not be misread: `thread` is not a read.
test('tool matching is exact, not substring', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('tool', '{}', 'thread_probe')];
  assert.equal(itemsOf(lines, policy(), new Map(), -1)[1].activity, 'tools');
});

// ── reasoning preview ──────────────────────────────────────────────────────────────────

test('a settled reasoning row shows its summary only when the policy asks for it', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '先看数据层', '')];
  const quiet = itemsOf(lines, policy('none', 'immediate', false), new Map(), -1);
  assert.equal(quiet[1].title, '思考');

  const preview = itemsOf(lines, policy('none', 'immediate', true), new Map(), -1);
  assert.equal(preview[1].title, '思考 · 先看数据层');
});

test('a live reasoning row shows its summary regardless of the policy', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '正在读', '')];
  const items = itemsOf(lines, policy('none', 'immediate', false), new Map(), RUNNING);
  assert.equal(items[1].title, '思考 · 正在读');
});
// ── incremental plan ────────────────────────────────────────────────────────────────────
//
// This is the case that shipped broken: the panel assumed "only the last item can change",
// updated just that one, and so a growing thought — which lives in the *group*, not at the
// tail — never re-rendered. Everything after the first delta was invisible.

const RUN = -1;

function tick(before: ChatLine[], after: ChatLine[], runningBefore = RUN, runningAfter = RUN) {
  return planItems(
    itemsOf(before, policy(), new Map(), runningBefore),
    itemsOf(after, policy(), new Map(), runningAfter)
  );
}

test('an unchanged frame updates nothing', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const plan = tick(lines, lines);
  assert.equal(plan.replaceAll, false);
  assert.deepEqual(plan.updateIndexes, []);
});

test('a growing thought updates the group, not the tail', () => {
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const after: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想得更久', ''), makeLine('assistant', '答', '')];
  const plan = tick(before, after);
  assert.deepEqual(plan.updateIndexes, [1]);
});

test('a growing answer updates the tail', () => {
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const after: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答得更长', '')];
  assert.deepEqual(tick(before, after).updateIndexes, [2]);
});

test('a delta that moves both the group and the answer reports both', () => {
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const after: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想更多', ''), makeLine('assistant', '答更多', '')];
  assert.deepEqual(tick(before, after).updateIndexes, [1, 2]);
});

test('a new tool joins the group without changing the item count', () => {
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const after: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{}', 'read'), makeLine('assistant', '答', '')
  ];
  const plan = tick(before, after);
  assert.equal(plan.replaceAll, false);
  // 组必须被更新，否则组头文案与组内成员停在上一帧。插入行会让后面项的 key 平移，
  // 多报几项只是多一次 update，不影响正确性。
  assert.ok(plan.updateIndexes.includes(1), '组没被更新');
  assert.ok(!plan.updateIndexes.includes(0), '用户消息没变却被更新');
});

test('the answer arriving adds a block of its own', () => {
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const after: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  assert.equal(tick(before, after).replaceAll, true, '项数从 2 变 3');
});

test('a shrunk transcript forces a full replace', () => {
  // 整组消失：项数从 2 变 1，只能整表替换。
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const after: ChatLine[] = [makeLine('user', 'Q', '')];
  assert.equal(tick(before, after).replaceAll, true);
});

test('an empty previous frame forces a full replace', () => {
  const after: ChatLine[] = [makeLine('user', 'Q', '')];
  assert.equal(planItems([], itemsOf(after, policy(), new Map(), RUN)).replaceAll, true);
});

test('opening a group by hand updates that group', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const plan = planItems(
    itemsOf(lines, policy(), new Map(), RUN),
    itemsOf(lines, policy(), new Map([['g0', true]]), RUN)
  );
  assert.deepEqual(plan.updateIndexes, [1]);
});

test('the turn finishing updates the group that closed', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('assistant', '答', '')];
  const plan = tick(lines, lines, 0, -1);
  // 组从「进行中」变「已完成」，组头文案跟着变，必须更新；
  // 正文项的 closed 也从 false 变 true，一并更新是对的。
  assert.ok(plan.updateIndexes.includes(1), '已结束的组没被更新');
});

test('same length, different text still counts as changed', () => {
  const before: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('assistant', '答A', '')];
  const after: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('assistant', '答B', '')];
  assert.deepEqual(tick(before, after).updateIndexes, [1]);
});

test('the digest covers every field that reaches the screen', () => {
  const base = makeLine('user', 'Q', '');
  const items = itemsOf([base], policy(), new Map(), RUN);
  const item = items[0];
  const digest = itemDigest(item);
  assert.equal(itemDigest(itemsOf([base], policy(), new Map(), RUN)[0]), digest);
  // 正文变化必须体现在摘要里，否则「只更新变了的那几项」会漏掉它。
  const longer = itemsOf([makeLine('user', 'Q more', '')], policy(), new Map(), RUN)[0];
  assert.notEqual(itemDigest(longer), digest);
});

// ── every combination of the four inputs ────────────────────────────────────────────────
//
// itemsOf takes four things that matter together: the view mode (3 values), whether the turn
// is still running (2), whether the turn produced an error (2), and whether the reader opened
// the group by hand (2). Hand-written cases covered a corner of that grid and missed the rest.
// These walk the whole grid and assert invariants instead of exact item lists, so a regression
// in any single cell fails here.

const GROUPINGS: StepGrouping[] = ['collapsed', 'history', 'none'];

function linesFor(withError: boolean): ChatLine[] {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('tool', '{}', 'read')];
  if (withError) {
    lines.push(makeLine('error', 'upstream 502', ''));
  }
  lines.push(makeLine('assistant', '答', ''));
  return lines;
}

function itemsFor(grouping: StepGrouping, running: boolean, withError: boolean, openByHand: boolean) {
  const lines = linesFor(withError);
  // 运行中：本轮从第 0 行开始；否则 -1 表示全部已结束。
  const runningStart = running ? 0 : -1;
  const opened = new Map<string, boolean>();
  if (openByHand) {
    const probe = itemsOf(lines, policy(grouping, 'immediate'), new Map(), runningStart);
    for (const item of probe) {
      if (item.kind === 'group') {
        opened.set(item.key, true);
      }
    }
  }
  return itemsOf(lines, policy(grouping, 'immediate'), opened, runningStart);
}

for (const grouping of GROUPINGS) {
  for (const running of [true, false]) {
    for (const withError of [true, false]) {
      for (const openByHand of [true, false]) {
        const label = `${grouping} / ${running ? 'running' : 'done'} / ${withError ? 'error' : 'clean'} / ${openByHand ? 'opened' : 'closed'}`;

        test(`invariants hold: ${label}`, () => {
          const items = itemsFor(grouping, running, withError, openByHand);
          const groups = items.filter((item: { kind: string }) => item.kind === 'group');
          const errors = items.filter((item: { kind: string }) => item.kind === 'error');

          // 1) 错误行永远不收起：收起等于把失败原因藏起来。
          for (const error of errors) {
            assert.equal(error.collapsed, false, '错误行被收起了');
          }
          // 2) 运行中的组永远展开。
          for (const group of groups) {
            if (!group.closed) {
              assert.equal(group.collapsed, false, '运行中的组被收起了');
            }
          }
          // 3) 组里有错误时，组不能收。
          if (withError) {
            for (const group of groups) {
              assert.equal(group.collapsed, false, '含错误的组被收起了');
            }
          }
          // 4) 手动展开必须压过收起。
          if (openByHand && !running) {
            for (const group of groups) {
              assert.equal(group.collapsed, false, '手动展开没生效');
            }
          }
          // 5) 全部档不分组，过程行逐行出现。
          if (grouping === 'none') {
            assert.equal(groups.length, 0, '全部档不该有组');
            assert.ok(
              items.filter((item: { kind: string }) => item.kind === 'reasoning').length > 0,
              '全部档该有逐行推理'
            );
          }
          // 6) 精简档对已结束、无错误、未手开的组必须收起；运行中则不分组之外必然展开。
          if (grouping === 'collapsed' && !running && !withError && !openByHand) {
            assert.equal(groups.length, 1, '精简档已结束该有一个组');
            assert.equal(groups[0].collapsed, true, '精简档已结束的组该收起');
          }
          // 7) 历史档：运行中的轮不分组，已结束的轮才分组。
          if (grouping === 'history') {
            assert.equal(groups.length, running ? 0 : 1, '历史档的分组条件不对');
          }
          // 8) 分组与逐行两种形态互斥：有组就没有逐行的过程行，反之亦然。
          //    （历史档在运行中不分组，那时候逐行出现是对的，所以判据要挂在「有没有组」上，
          //      而不是挂在档位上。）
          if (groups.length > 0) {
            assert.equal(
              items.filter((item: { kind: string }) => item.kind === 'reasoning').length, 0,
              '分组了却还有逐行推理'
            );
            assert.equal(
              items.filter((item: { kind: string }) => item.kind === 'tool').length, 0,
              '分组了却还有逐行工具'
            );
          } else {
            assert.equal(
              items.filter((item: { kind: string }) => item.kind === 'reasoning').length, 1,
              '没分组却没有逐行推理'
            );
          }
          // 9) 答案一定在：分组时它是组的成员，不分组时它是一块正文。
          //    折叠只许改变它在哪，不许让它消失（DSH 的 compactAnswer）。
          const outside = items.filter((item: { kind: string }) => item.kind === 'markdown').length;
          let inside = 0;
          for (const group of groups) {
            for (const member of group.process) {
              if (member.kind === 'assistant') {
                inside += 1;
                break;
              }
            }
          }
          assert.equal(outside + inside, 1, '答案丢了');
        });
      }
    }
  }
}

// ── edges the grid above does not reach ─────────────────────────────────────────────────

test('an injection line becomes its own item, not part of a group', () => {
  const lines: ChatLine[] = [
    makeLine('injection', 'runtime context', 'AGENTS.md'),
    makeLine('user', 'Q', ''), makeLine('thought', '想', '')
  ];
  const items = itemsOf(lines, policy(), new Map(), RUN);
  assert.deepEqual(shape(items), ['injection', 'user', 'group']);
  assert.equal(items[0].title, 'AGENTS.md');
});

test('a checkpoint line becomes an injection item', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('checkpoint', 'seq 10-40\n旧内容', '压缩点')
  ];
  const items = itemsOf(lines, policy(), new Map(), RUN);
  assert.deepEqual(shape(items), ['user', 'injection']);
});

test('consecutive user lines with no process produce no group', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q1', ''), makeLine('user', 'Q2', '')];
  const items = itemsOf(lines, policy(), new Map(), RUN);
  assert.deepEqual(shape(items), ['user', 'user']);
});

test('a group made only of tools still gets a header', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('tool', '{}', 'read')];
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.equal(items[1].kind, 'group');
  assert.equal(items[1].title, '已读取文件');
  assert.equal(items[1].activity, 'read');
});

test('a turn with steps folds its process, and its answer stays visible', () => {
  // 折起来的是过程（更早的消息、思考、工具）；答案一直在组外——整轮折起来后仍看得到回答。
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''),
    makeLine('thought', '想一', ''),
    makeLine('assistant', '过程里的一段', ''),
    makeLine('tool', '{}', 'grep'),
    makeLine('assistant', '答案', '')
  ];
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'group', 'markdown']);
  const group = items.filter((item: { kind: string }) => item.kind === 'group')[0];
  assert.equal(group.process.length, 3, '思考、过程消息、工具在组里');
  assert.equal(group.collapsed, true);
  const body = items.filter((item: { kind: string }) => item.kind === 'markdown')[0];
  assert.equal(body.text, '答案');
});

test('a stale key in the open map does not break anything', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const opened = new Map<string, boolean>([['g999', true], ['b999', true]]);
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'group']);
  assert.equal(items[1].collapsed, true);
});

test('next-input does not resurrect a group that is still running', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const items = itemsOf(lines, policy('collapsed', 'next-input'), new Map(), 0);
  assert.equal(items[1].collapsed, false);
  assert.equal(items[1].closed, false);
});

test('an unknown collapse timing degrades to immediate', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const items = itemsOf(lines, policy('collapsed', 'bogus' as 'immediate'), new Map(), -1);
  assert.equal(items[1].collapsed, true);
});

test('an unknown step grouping degrades to inlining', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const items = itemsOf(lines, policy('bogus' as StepGrouping), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'reasoning']);
});

test('a single-line checkpoint expands to nothing, since its title already showed the line', () => {
  assert.equal(lineDetail(makeLine('checkpoint', 'seq 1-5', '压缩点')), '');
});

// ── property: the incremental path must equal a full recompute ──────────────────────────
//
// 这一节照「行为」写，不照实现写：用真实的 appendLine 生成 delta，每步只把增量计划应用到
// 数据源上，然后要求数据源与「从零全量重算」逐项一致。任何漏更新的项都会在这里炸掉——
// 包括当初那个「项数没变就只更新末项」的写法，下面留了它当反面对照。

class FakeSource {
  items: StreamItem[] = [];
  replace(next: StreamItem[]): void {
    this.items = next;
  }
  update(at: number, item: StreamItem): void {
    this.items[at] = item;
  }
  snapshot(): StreamItem[] {
    return this.items;
  }
}

/** ChatPanel.applyItems 的增量分支（不含 forceReplace 与 hilog）。 */
function applyPlan(source: FakeSource, next: StreamItem[]): void {
  const plan = planItems(source.snapshot(), next);
  if (plan.replaceAll) {
    source.replace(next);
    return;
  }
  for (const at of plan.updateIndexes) {
    source.update(at, next[at]);
  }
}

/** 曾经的做法：项数没变就只更新末项。 */
function applyTailOnly(source: FakeSource, next: StreamItem[]): void {
  if (source.items.length === next.length && next.length > 0) {
    source.update(next.length - 1, next[next.length - 1]);
    return;
  }
  source.replace(next);
}

/** 数据源与全量结果的第一处差异，空串表示一致。 */
function desync(source: FakeSource, fresh: StreamItem[]): string {
  if (source.items.length !== fresh.length) {
    return '项数不一致';
  }
  for (let i = 0; i < fresh.length; i += 1) {
    if (itemDigest(source.items[i]) !== itemDigest(fresh[i])) {
      return '第 ' + String(i) + ' 项没同步';
    }
  }
  return '';
}

function seeded(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1103515245 + 12345) % 2147483648;
    return state / 2147483648;
  };
}

function lastUserIndex(lines: ChatLine[]): number {
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (lines[i].kind === 'user') {
      return i;
    }
  }
  return -1;
}

test('applying the plan equals a full recompute over a random delta stream', () => {
  const rand = seeded(20251115);
  const kinds: string[] = ['thought', 'text', 'tool', 'error'];
  let lines: ChatLine[] = appendLine([], 'user', 'Q0');
  let turnStart = 0;
  const source = new FakeSource();
  for (let step = 0; step < 400; step += 1) {
    if (rand() < 0.05) {
      lines = appendLine(lines, 'user', 'Q' + String(step));
      turnStart = lastUserIndex(lines);
    } else {
      const kind = kinds[Math.floor(rand() * kinds.length)];
      lines = appendLine(lines, kind, 'w' + String(Math.floor(rand() * 90)) + ' s' + String(step));
    }
    const runningStart: number = rand() < 0.25 ? turnStart : -1;
    const fresh = itemsOf(lines, policy(), new Map(), runningStart);
    applyPlan(source, fresh);
    const why = desync(source, fresh);
    assert.equal(why, '', '第 ' + String(step) + ' 步：' + why);
  }
  // 这一串里必须真的产生过多轮与组，否则上面的断言是空的。
  assert.ok(source.items.length >= 3, '随机序列没长出足够多的块');
});

test('the tail-only rule desyncs when an earlier turn changes', () => {
  // 反面对照：只更新末项的写法，遇到「前面那一轮变了、末项没变」就漏更新。
  const first = [makeLine('user', 'Q1', ''), makeLine('thought', '想一', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', '想二', '')];
  const source = new FakeSource();
  applyTailOnly(source, itemsOf(first, policy(), new Map(), -1));

  const second = [makeLine('user', 'Q1', ''), makeLine('thought', '想一变长了', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', '想二', '')];
  const fresh = itemsOf(second, policy(), new Map(), -1);
  applyTailOnly(source, fresh);
  assert.notEqual(desync(source, fresh), '', '只更新末项的写法本该漏掉前面那一组——反面对照失效了');

  // 同样的输入，走增量计划就必须一致。
  const planned = new FakeSource();
  applyPlan(planned, itemsOf(second, policy(), new Map(), -1));
  assert.equal(desync(planned, fresh), '');
});

test('a thought arriving after the answer is spliced in front, and stays in the group', () => {
  // ChatView 把后到的思考插到正文之前（推理先于回答）：组里只有那段思考，答案在组外。
  let lines: ChatLine[] = appendLine([], 'user', 'Q');
  lines = appendLine(lines, 'text', '答');
  lines = appendLine(lines, 'thought', '后到的思考');
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'group', 'markdown']);
  assert.equal(items[1].process.length, 1);
  assert.equal(items[1].process[0].kind, 'thought');
  assert.equal(items[2].text, '答');
});

test('an unknown event kind is shown as text rather than silently dropped', () => {
  const lines = appendLine([], 'content', '正文');
  assert.equal(lines.length, 1);
  assert.equal(lines[0].kind, 'assistant');
  assert.equal(lines[0].text, '正文');
});

test('the same activity twice is named once in the header', () => {
  // 两次 read：活动集只有一个元素，标题不该说「已读取文件并已读取文件」。
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''),
    makeLine('tool', '{"path":"a"}', 'read'),
    makeLine('tool', '{"path":"b"}', 'read')
  ];
  assert.equal(itemsOf(lines, policy(), new Map(), -1)[1].title, '已读取文件');
});

test('two different tools of the same kind still name one activity', () => {
  // grep 与 glob 都算 search，同样只算一类。
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''),
    makeLine('tool', '{}', 'grep'),
    makeLine('tool', '{}', 'glob')
  ];
  assert.equal(itemsOf(lines, policy(), new Map(), -1)[1].title, '已搜索代码');
});

// ── closable ────────────────────────────────────────────────────────────────────────────
//
// 开合由组件读 opened 自己算，closable 是它唯一的输入。这条契约错了，表现就是
// 「点了没反应」或者「错误被藏起来」——两种都难以从症状反推。

test('a finished group is closable, a running one is not', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  assert.equal(itemsOf(lines, policy(), new Map(), 0)[1].closable, false);
  assert.equal(itemsOf(lines, policy(), new Map(), -1)[1].closable, true);
});

test('a group holding an error is not closable', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('error', '502', '')
  ];
  assert.equal(itemsOf(lines, policy(), new Map(), -1)[1].closable, false);
});

test('process rows are closable, content rows are not', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q', ''), makeLine('thought', '想', ''), makeLine('error', '502', '')
  ];
  const items = itemsOf(lines, policy('none'), new Map(), -1);
  assert.equal(items[0].closable, false, '用户消息不该可收起');
  assert.equal(items[1].closable, true, '推理行该可收起');
  assert.equal(items[2].closable, false, '错误行不该可收起');
});

test('nothing is collapsed unless it is closable', () => {
  // closable=false 与 collapsed=true 同时出现，就是「读者永远打不开它」的死项。
  for (const grouping of GROUPINGS) {
    for (const withError of [true, false]) {
      const items = itemsOf(linesFor(withError), policy(grouping), new Map(), -1);
      for (const item of items) {
        if (!item.closable) {
          assert.equal(item.collapsed, false, grouping + '：不可收起却被算成收起');
        }
      }
    }
  }
});


test('a turn without steps still shows its answer as a block', () => {
  const lines = [makeLine('user', 'Q', ''), makeLine('assistant', '只有答案', '')];
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'markdown']);
});

test('a real paragraph break inside one message is preserved', () => {
  const lines = [makeLine('user', 'Q', ''), makeLine('assistant', '甲。\n\n乙。', '')];
  const body = itemsOf(lines, policy(), new Map(), -1)
    .filter((item: { kind: string }) => item.kind === 'markdown');
  assert.equal(body[0].text, '甲。\n\n乙。');
});

test('the project’s own tools map to a real activity', () => {
  // 认不出来会落到「调用工具」兜底档，组头图标也就成了默认那条横线。
  assert.equal(activityOfTool('read_log'), 'read');
  assert.equal(activityOfTool('sdk_search'), 'search');
  assert.equal(activityOfTool('ide'), 'edit');
  assert.equal(activityOfTool('todo_read'), 'plan');
  assert.equal(activityOfTool('没见过'), 'tools');
});

test('a message inside the group renders as text, a step as a step', () => {
  // 组里既有「当时说过的话」也有「做过的一步」。前者直接给文字，后者才配一个可点开的标题。
  assert.equal(memberStyle(makeLine('assistant', '话', '')), 'plain');
  assert.equal(memberStyle(makeLine('thought', '想', '')), 'step');
  assert.equal(memberStyle(makeLine('tool', '{}', 'read')), 'step');
});

// ── the four view modes, one by one ──────────────────────────────────────────────────────
//
// DSH 的四档（presentation-policy.js 的 POLICIES）：
//   compact  foldCompleted + collapsed + liveProcessDetail off + settledPreview off
//   standard foldCompleted + collapsed + liveProcessDetail on  + settledPreview on
//   detailed foldCompleted + history   + liveProcessDetail on  + settledPreview on
//   verbose  no fold     + none        + liveProcessDetail off + settledPreview on
// 这里的断言逐档钉住「什么时候折、组头说什么」。

const CLOSED_TURN: ChatLine[] = [
  makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
  makeLine('tool', '{"cmd":"ls"}', 'shell'), makeLine('assistant', '答', '')
];

test('compact: a finished turn folds its process, answer stays out, no live detail', () => {
  const items = itemsOf(CLOSED_TURN, policy('collapsed', 'immediate', false, false), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'group', 'markdown']);
  assert.equal(items[1].collapsed, true);
  assert.equal(items[1].title, '已完成分析并执行了命令');
});

test('compact: a running turn stays open and its header carries no detail', () => {
  const live: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{"cmd":"ls"}', 'shell')];
  const items = itemsOf(live, policy('collapsed', 'immediate', false, false), new Map(), 0);
  assert.equal(items[1].collapsed, false);
  assert.equal(items[1].title, '正在分析请求并正在运行命令', '精简档组头不该带命令细节');
});

test('standard: same folding, but the live header shows what is running', () => {
  const live: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{"cmd":"ls"}', 'shell')];
  const items = itemsOf(live, policy('collapsed', 'immediate', true, true), new Map(), 0);
  assert.equal(items[1].collapsed, false);
  assert.ok(items[1].title.indexOf('{"cmd":"ls"}') >= 0, '标准档组头该带正在跑的命令');
});

test('detailed: finished turns fold, the live turn does not', () => {
  const lines: ChatLine[] = [
    makeLine('user', 'Q1', ''), makeLine('thought', '想1', ''), makeLine('assistant', 'A1', ''),
    makeLine('user', 'Q2', ''), makeLine('thought', '想2', '')
  ];
  const items = itemsOf(lines, policy('history', 'immediate', true, true), new Map(), 3);
  assert.deepEqual(shape(items), ['user', 'group', 'markdown', 'user', 'reasoning'],
    '详细档：已结束的轮折起来（答案在外），正在跑的那轮逐行给');
});

test('verbose: nothing folds, every process line is inline and in order', () => {
  const items = itemsOf(CLOSED_TURN, policy('none', 'immediate', true, false), new Map(), -1);
  assert.deepEqual(shape(items), ['user', 'reasoning', 'tool', 'markdown']);
  assert.equal(kinds(items, 'group'), 0);
});

test('the live detail shows the running step, and is cut when long', () => {
  // 组里最后一步是工具：细节取它的参数，过长截断。
  const long: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{"cmd":"' + 'x'.repeat(40) + '"}', 'shell')];
  const items = itemsOf(long, policy('collapsed', 'immediate', true, true), new Map(), 0);
  assert.ok(items[1].title.indexOf('…') >= 0, '过长的细节该截断');

  // 组里最后一步是「过程消息」（不是答案）：细节取那句话的第一行。
  const talk: ChatLine[] = [makeLine('user', 'Q', ''),
    makeLine('assistant', '第一行\n第二行', ''), makeLine('assistant', '答案', '')];
  const live = itemsOf(talk, policy('collapsed', 'immediate', true, true), new Map(), 0);
  assert.ok(live[1].title.indexOf('第一行') >= 0);
  assert.ok(live[1].title.indexOf('第二行') < 0, '细节只取第一行');
});

test('a group whose members are all errors has no live detail to show', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', '')];
  const items = itemsOf(lines, policy('collapsed', 'immediate', true, true), new Map(), 0);
  // 只有思考、没有工具与回答：细节为空，标题结尾不该挂一个空冒号。
  assert.equal(items[1].title.indexOf('：'), -1);
});

test('a group of nothing but messages still says something real', () => {
  // 这一轮有两段话、没有工具也没有思考：组头不能说「已调用工具」。
  const lines: ChatLine[] = [makeLine('user', 'Q', ''),
    makeLine('assistant', '先说一句', ''), makeLine('assistant', '再说一句', '')];
  const items = itemsOf(lines, policy(), new Map(), -1);
  assert.equal(items[1].kind, 'group', '有过程可折时才该成组');
  assert.equal(items[1].title, '已完成分析');
});

test('the live detail falls back to the tool name, and cuts a long sentence', () => {
  // 工具没有参数时用名字；最后一步是话且很长时按第一行截断。
  const bare: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('tool', '', 'todo_read')];
  const bareItems = itemsOf(bare, policy('collapsed', 'immediate', true, true), new Map(), 0);
  assert.ok(bareItems[1].title.indexOf('todo_read') >= 0, '没有参数时该报工具名');

  // 最后一轮成员是「很长的一句话」：要成组才谈得上组头细节，所以前面带一段思考。
  // 组里最后一步是「过程消息」（有答案跟在后头）：细节取它第一行，过长截断。
  const longTalk: ChatLine[] = [makeLine('user', 'Q', ''),
    makeLine('assistant', '这是一句很长很长的话' + '。'.repeat(20), ''),
    makeLine('assistant', '答案', '')];
  const items = itemsOf(longTalk, policy('collapsed', 'immediate', true, true), new Map(), 0);
  const group = items.filter((item: { kind: string }) => item.kind === 'group')[0];
  assert.ok(group.title.indexOf('…') >= 0, '过长的话该截断');
});

test('whether a member shows a preview comes from the mode, not the view', () => {
  // 精简档 settledReasoningPreview=false：组里的「思考」只写两个字；
  // 标准/详细打开：标题后面带首行摘要。
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想一\n想二', ''),
    makeLine('assistant', '答', '')];
  const compact = itemsOf(lines, policy('collapsed', 'immediate', false, false), new Map(), -1)[1];
  assert.equal(compact.memberPreview, false);
  const standard = itemsOf(lines, policy('collapsed', 'immediate', true, true), new Map(), -1)[1];
  assert.equal(standard.memberPreview, true);
});

test('compact folds even while the turn is still running', () => {
  // 「精简」的语义：先占一行，想看过程自己点开。跑着的这一轮也一样折。
  const live: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('tool', '{}', 'read')];
  const compactPolicy: ChatPresentationPolicy = {
    stepGrouping: 'collapsed',
    settledReasoningPreview: false,
    liveProcessDetail: false,
    foldWhileRunning: true,
    collapseTiming: 'immediate'
  };
  const items = itemsOf(live, compactPolicy, new Map(), 0);
  assert.deepEqual(shape(items), ['user', 'group']);
  assert.equal(items[1].collapsed, true, '精简档跑着也该收起');
  assert.equal(items[1].closable, true, '收起之后仍然可以点开');
});

test('flipping the preview changes the digest, so the row is redrawn on a mode switch', () => {
  const lines: ChatLine[] = [makeLine('user', 'Q', ''), makeLine('thought', '想', ''),
    makeLine('assistant', '答', '')];
  const off = itemsOf(lines, policy('collapsed', 'immediate', false, false), new Map(), -1)[1];
  const on = itemsOf(lines, policy('collapsed', 'immediate', true, true), new Map(), -1)[1];
  assert.equal(off.memberPreview, false);
  assert.equal(on.memberPreview, true);
  assert.notEqual(itemDigest(off), itemDigest(on), '换档后摘要没变，那一行不会被重画');
});

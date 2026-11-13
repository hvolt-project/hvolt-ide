// Tests for the event-sourced session. Run with: node --test test/
//
// The properties worth pinning are the ones a phone makes expensive to notice: that a compaction
// hides a range without deleting it, that seq identifies an event rather than a message, that a
// log interrupted mid-turn can be reopened without lying about what ran, and that one bad or
// truncated character cannot cost the file.

import test from 'node:test';
import assert from 'node:assert/strict';

import { Session, parseSpan } from '../app/src/pages/harness/session/Session.ts';
import { foldSurface, deriveMessages, unansweredCalls, openTurn } from '../app/src/pages/harness/session/Surface.ts';
import { defaultSpec, planRegion, retainTokens, triggerTokens, historyTokens } from '../app/src/pages/harness/session/Compact.ts';
import { parseLog, serializeLog, wellFormed, closeOpenTail } from '../app/src/pages/harness/session/Log.ts';
import type { SessionEvent } from '../app/src/pages/harness/session/Events.ts';
import type { ToolCall } from '../app/src/pages/harness/loop/Types.ts';

function call(id: string, name: string): ToolCall {
  return { id: id, name: name, argumentsJson: '{}' };
}

function conversation(turns: number, perTurn: number): Session {
  const session = new Session();
  session.setSystem('system prompt', 1);
  let at = 2;
  for (let turn = 0; turn < turns; turn++) {
    session.beginTurn(at++);
    session.appendUser('q' + turn + ' ' + 'x'.repeat(40), '', [], at++);
    for (let step = 0; step < perTurn; step++) {
      session.appendAssistant('a' + turn + '.' + step + ' ' + 'y'.repeat(40), [], '', at++);
    }
    session.endTurn('done', at++);
  }
  return session;
}

test('seq numbers events, not messages', () => {
  const session = new Session();
  session.setSystem('s', 1);
  session.beginTurn(2);
  session.appendUser('hi', '', [], 3);
  session.endTurn('done', 4);
  const types = session.all().map((event: SessionEvent) => event.type);
  assert.deepEqual(types, ['system/message', 'turn/start', 'user/message', 'turn/end']);
  const seqs = session.all().map((event: SessionEvent) => event.seq);
  assert.deepEqual(seqs, [0, 1, 2, 3]);
});

test('a replace hides its range and keeps the log intact', () => {
  const session = conversation(3, 1);
  const before = session.all().length;
  const nodes = session.nodes();
  const region = { startSeq: nodes[1].seq, endSeq: nodes[2].seq, tokens: 10 };
  const outcome = session.finishCompaction(region, 'the first turn happened', 99, 1);
  assert.notEqual(outcome, null);
  // The log grew: nothing was removed.
  assert.ok(session.all().length > before);
  assert.equal(session.all().length, before + 3);
  const messages = deriveMessages(session.all());
  const text = messages.map((m) => m.content).join('\n');
  assert.ok(text.includes('the first turn happened'));
  assert.ok(!text.includes('q0'), 'the replaced range is gone from the request');
  assert.ok(text.includes('q1'), 'later turns survive');
  // Recall still reaches the originals.
  const originals = session.originals(region.startSeq, region.endSeq);
  assert.ok(originals.length > 0);
  assert.ok(originals[0].content.includes('q0'));
});

test('the replacement sits where the first replaced node was', () => {
  const session = conversation(3, 1);
  const nodes = session.nodes();
  const region = { startSeq: nodes[1].seq, endSeq: nodes[1].seq, tokens: 5 };
  session.finishCompaction(region, 'summary', 99, 1);
  const messages = deriveMessages(session.all());
  assert.equal(messages[0].role, 'system');
  assert.equal(messages[1].role, 'user');
  assert.ok(messages[1].content.includes('<compacted-summary>'));
});

test('an open turn is closed with results for the calls it left behind', () => {
  const session = new Session();
  session.setSystem('s', 1);
  session.beginTurn(2);
  session.appendUser('go', '', [], 3);
  session.appendAssistant('', [call('c1', 'shell')], '', 4);
  session.noteToolCall(call('c1', 'shell'), 5);
  // Crash here: no result, no turn/end.
  const dumps = session.dump();
  const reopened = new Session();
  reopened.load(dumps);
  const types = reopened.all().map((event: SessionEvent) => event.type);
  assert.ok(types.includes('tool/result'));
  assert.ok(types.includes('turn/end'));
  assert.equal(reopened.openTurn(), -1);
  const result = reopened.all().filter((event: SessionEvent) => event.type === 'tool/result')[0];
  assert.ok(result.content.includes('outcome is unknown'));
  assert.equal(result.callId, 'c1');
});

test('a call that never started gets the not-started text', () => {
  const session = new Session();
  session.beginTurn(1);
  session.appendUser('go', '', [], 2);
  session.appendAssistant('', [call('c9', 'build')], '', 3);
  const events: SessionEvent[] = session.all();
  const open = unansweredCalls(events);
  assert.equal(open.length, 1);
  assert.equal(open[0].unstarted, true);
  const repair = closeOpenTail(events, 10, 'interrupted');
  const result = repair.filter((event: SessionEvent) => event.type === 'tool/result')[0];
  assert.ok(result.content.includes('before it was recorded as started'));
});

test('a compaction range starts after the system prompt and keeps a tail', () => {
  const session = conversation(20, 3);
  const spec = defaultSpec(2000, 256);
  const region = planRegion(session.nodes(), spec);
  assert.notEqual(region, null);
  const nodes = session.nodes();
  assert.ok(nodes[0].message.role === 'system');
  assert.notEqual(region!.startSeq, nodes[0].seq, 'the system prompt is never replaced');
  const retained = historyTokens(session.messages().filter((m) => m.id >= region!.endSeq + 1));
  assert.ok(retained > 0);
  assert.ok(region!.tokens > retainTokens(spec) || region!.tokens > 0);
});

test('a range boundary never strands a tool result', () => {
  const session = new Session();
  session.setSystem('s', 1);
  session.beginTurn(2);
  session.appendUser('go', '', [], 3);
  session.appendAssistant('', [call('c1', 'read')], '', 4);
  session.appendToolResult('c1', 'file body', false, 5);
  session.appendAssistant('done', [], '', 6);
  session.endTurn('done', 7);
  const nodes = session.nodes();
  // Force a region that would otherwise end on the result.
  const spec = defaultSpec(40, 10);
  const region = planRegion(nodes, spec);
  if (region !== null) {
    const covered = nodes.filter((n) => n.seq >= region.startSeq && n.seq <= region.endSeq);
    const last = covered[covered.length - 1];
    assert.notEqual(last.message.role, 'tool', 'the retained tail never starts with a result');
  }
});

test('the log round-trips through jsonl', () => {
  const session = conversation(4, 2);
  session.appendToolResult('c1', 'body', true, 50);
  const text = session.dump();
  const back = new Session();
  back.load(text);
  assert.equal(back.all().length, session.all().length);
  assert.deepEqual(
    back.messages().map((m) => m.content),
    session.messages().map((m) => m.content)
  );
});

test('a lone surrogate does not break the file', () => {
  const broken = 'ok\ud83d';
  const repaired = wellFormed(broken);
  assert.ok(!/[\ud800-\udbff](?![\udc00-\udfff])/.test(repaired));
  const session = new Session();
  session.beginTurn(1);
  session.appendUser(broken, '', [], 2);
  const text = session.dump();
  const rows = text.trim().split('\n');
  for (const row of rows) {
    assert.doesNotThrow(() => JSON.parse(row));
  }
});

test('a corrupt line costs only itself', () => {
  const session = conversation(2, 1);
  const lines = session.dump().trim().split('\n');
  lines.splice(2, 0, '{"type":"user/message","seq":99,"content":');
  const back = new Session();
  back.load(lines.join('\n') + '\n');
  assert.equal(back.all().length, session.all().length);
});

test('transcript pages by turn and the outline previews each turn', () => {
  const session = conversation(5, 1);
  const all = session.transcript(0);
  assert.ok(all.length >= 10);
  const lastTwo = session.transcript(2);
  assert.ok(lastTwo.length < all.length);
  const text = lastTwo.map((m) => m.content).join('\n');
  assert.ok(text.includes('q3'));
  assert.ok(text.includes('q4'));
  assert.ok(!text.includes('q0'));
  const outline = session.turns();
  assert.equal(outline.length, 5);
  assert.ok(outline[0].prompt.startsWith('q0'));
  assert.ok(outline[4].response.includes('a4.0'));
});

test('parseSpan reads one id or an inclusive span', () => {
  assert.deepEqual(parseSpan('12'), [12, 12]);
  assert.deepEqual(parseSpan('3-7'), [3, 7]);
  assert.deepEqual(parseSpan('7-3'), [3, 7]);
  assert.deepEqual(parseSpan('x'), [-1, -1]);
});

test('the trigger line follows dsh-compaction-basic', () => {
  // floor(min(W * 0.8, W - O - 65536)) with a 1M window and an 8K output cap.
  const big = defaultSpec(1000000, 8192);
  assert.equal(triggerTokens(big), Math.min(800000, 1000000 - 8192 - 65536));
  // A small window cannot satisfy the headroom rule, so the ratio decides.
  const small = defaultSpec(32000, 2048);
  assert.equal(triggerTokens(small), 25600);
  assert.equal(retainTokens(small), Math.floor((32000 - 2048) * 0.16));
});

test('a compaction lock blocks a second start until it closes', () => {
  const session = conversation(20, 3);
  session.setContextWindow(1000, 128);
  const first = session.beginCompaction(100, 'pressure');
  assert.notEqual(first, null);
  const second = session.beginCompaction(101, 'pressure');
  assert.equal(second, null, 'an unmatched start is the lock');
  session.abortCompaction('failed', 102);
  const third = session.beginCompaction(103, 'pressure');
  assert.notEqual(third, null);
});
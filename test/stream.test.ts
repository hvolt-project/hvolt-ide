// Tests for the streaming chat decoder: SSE framing and delta application.
//
// These cover what the transport callback used to do inline: a chunk boundary can fall inside a
// line or inside a multi-byte character, tool-call arguments arrive in pieces, and the model can
// report text, reasoning, both, or neither in any given delta.

import test from 'node:test';
import assert from 'node:assert/strict';
import { totalTokensOf } from '../app/src/pages/harness/loop/Types.ts';

import { applyDelta, collectCalls, cutLines, ssePayload } from '../app/src/pages/harness/loop/Stream.ts';
import { pairToolResults, unpairedCalls } from '../app/src/pages/harness/loop/Wire.ts';
import type { ToolCallChunk } from '../app/src/pages/harness/loop/Stream.ts';
import type { ChatMessage } from '../app/src/pages/harness/loop/Types.ts';

function delta(content: string): string {
  return JSON.stringify({ choices: [{ delta: { content: content } }] });
}

test('a complete line is cut from the buffer', () => {
  const [lines, rest] = cutLines('data: one\ndata: two\n');
  assert.deepEqual(lines, ['data: one', 'data: two']);
  assert.equal(rest[0], '');
});

test('an incomplete tail is carried, not parsed', () => {
  const [lines, rest] = cutLines('data: one\ndata: tw');
  assert.deepEqual(lines, ['data: one']);
  assert.equal(rest[0], 'data: tw');
});

test('a line spanning chunks survives two passes', () => {
  const [first, rest] = cutLines('data: {"choi');
  assert.deepEqual(first, []);
  const [second, rest2] = cutLines(rest[0] + 'ces":[]}\n');
  assert.deepEqual(second, ['data: {"choices":[]}']);
  assert.equal(rest2[0], '');
});

test('ssePayload extracts the body and ignores non-data lines', () => {
  assert.equal(ssePayload('data: {"a":1}'), '{"a":1}');
  assert.equal(ssePayload('data:{"a":1}'), '{"a":1}');
  assert.equal(ssePayload(':keep-alive'), '');
  assert.equal(ssePayload(''), '');
});

test('the DONE sentinel yields no payload', () => {
  assert.equal(ssePayload('data: [DONE]'), '');
});

test('content accumulates across deltas', () => {
  const text: string[] = [];
  const calls = new Map<number, ToolCallChunk>();
  const seen: string[] = [];
  applyDelta(delta('Hello'), text, calls, { onText: (p) => seen.push(p) });
  const joined = applyDelta(delta(' world'), text, calls, { onText: (p) => seen.push(p) });
  assert.equal(joined, 'Hello world');
  assert.deepEqual(seen, ['Hello', ' world']);
});

test('reasoning_content is reported separately from content', () => {
  const text: string[] = [];
  const thoughts: string[] = [];
  const payload = JSON.stringify({ choices: [{ delta: { reasoning_content: 'thinking' } }] });
  applyDelta(payload, text, new Map(), { onThought: (p) => thoughts.push(p) });
  assert.deepEqual(thoughts, ['thinking']);
  assert.equal(text.length, 0);
});

test('reasoning is accepted as an alias', () => {
  const thoughts: string[] = [];
  const payload = JSON.stringify({ choices: [{ delta: { reasoning: 'why' } }] });
  applyDelta(payload, [], new Map(), { onThought: (p) => thoughts.push(p) });
  assert.deepEqual(thoughts, ['why']);
});

test('a malformed payload is skipped without throwing', () => {
  const text: string[] = [];
  const joined = applyDelta('{not json', text, new Map(), {});
  assert.equal(joined, '');
});

test('usage is reported when present and tolerates missing fields', () => {
  const seen: number[] = [];
  const payload = JSON.stringify({
    usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13 },
    choices: []
  });
  applyDelta(payload, [], new Map(), { onUsage: (u) => seen.push(totalTokensOf(u)) });
  assert.deepEqual(seen, [13]);

  const partial: number[] = [];
  applyDelta(JSON.stringify({ usage: {}, choices: [] }), [], new Map(),
    { onUsage: (u) => partial.push(totalTokensOf(u)) });
  assert.deepEqual(partial, [0]);
});

test('a usage-only delta is not mistaken for content', () => {
  const text: string[] = [];
  applyDelta(JSON.stringify({ usage: { total_tokens: 5 }, choices: [] }), text, new Map(), {});
  assert.equal(text.length, 0);
});

test('tool call arguments accumulate across deltas', () => {
  const calls = new Map<number, ToolCallChunk>();
  const text: string[] = [];
  applyDelta(JSON.stringify({
    choices: [{ delta: { tool_calls: [{ index: 0, id: 'c1', function: { name: 'read', arguments: '{"pa' } }] } }]
  }), text, calls, {});
  applyDelta(JSON.stringify({
    choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'th":"a"}' } }] } }]
  }), text, calls, {});
  assert.equal(calls.get(0)?.name, 'read');
  assert.equal(calls.get(0)?.argumentsJson, '{"path":"a"}');
});

test('two tool calls are tracked independently by index', () => {
  const calls = new Map<number, ToolCallChunk>();
  applyDelta(JSON.stringify({
    choices: [{ delta: { tool_calls: [
      { index: 0, id: 'a', function: { name: 'one', arguments: '{}' } },
      { index: 1, id: 'b', function: { name: 'two', arguments: '{}' } }
    ] } }]
  }), [], calls, {});
  const collected = collectCalls(calls);
  assert.equal(collected.length, 2);
  assert.deepEqual(collected.map((c) => c.name).sort(), ['one', 'two']);
});

test('collectCalls fills an id and arguments when the stream omits them', () => {
  const collected = collectCalls(new Map([[0, { index: 0, id: '', name: 'act', argumentsJson: '' }]]));
  assert.equal(collected.length, 1);
  assert.equal(collected[0].id, 'call_0');
  assert.equal(collected[0].argumentsJson, '{}');
});

test('collectCalls drops entries with no name', () => {
  assert.deepEqual(collectCalls(new Map([[0, { index: 0, id: 'x', name: '', argumentsJson: '{}' }]])), []);
});

test('a delta with no choices leaves the text untouched', () => {
  const text: string[] = [];
  applyDelta(JSON.stringify({ choices: [] }), text, new Map(), {});
  assert.equal(text.length, 0);
});

test('pairing pulls tool results next to their call, in call order', () => {
  const messages = [
    { id: 0, role: 'assistant', source: 'model', content: '', reasoning: '', context: '', images: [],
      toolCalls: [{ id: 'c1', name: 'read', argumentsJson: '{}' }, { id: 'c2', name: 'grep', argumentsJson: '{}' }], toolCallId: '' },
    { id: 1, role: 'user', source: 'human', content: '插进来的消息', reasoning: '', context: '', images: [],
      toolCalls: [], toolCallId: '' },
    { id: 2, role: 'tool', source: 'tool', content: 'second', reasoning: '', context: '', images: [],
      toolCalls: [], toolCallId: 'c2' },
    { id: 3, role: 'tool', source: 'tool', content: 'first', reasoning: '', context: '', images: [],
      toolCalls: [], toolCallId: 'c1' }
  ] as ChatMessage[];
  assert.ok(unpairedCalls(messages).length > 0, 'the log as written breaks the protocol');
  const fixed = pairToolResults(messages);
  assert.deepEqual(unpairedCalls(fixed), [], 'after pairing the request is valid');
  assert.deepEqual(fixed.slice(0, 3).map((m) => m.toolCallId), ['', 'c1', 'c2']);
  assert.equal(fixed.length, messages.length, 'nothing is dropped');
});

test('a call with no result gets a placeholder that keeps the protocol valid', () => {
  const messages = [
    { id: 0, role: 'assistant', source: 'model', content: '', reasoning: '', context: '', images: [],
      toolCalls: [{ id: 'c9', name: 'shell', argumentsJson: '{}' }], toolCallId: '' }
  ] as ChatMessage[];
  const fixed = pairToolResults(messages);
  assert.equal(fixed.length, 2);
  assert.equal(fixed[1].role, 'tool');
  assert.equal(fixed[1].toolCallId, 'c9');
  assert.deepEqual(unpairedCalls(fixed), []);
});

// Approval is decided in the dispatcher, not inside each tool. These cases pin that: a tool that
// declares confirm is asked before its handler runs, a refusal comes back as a tool result rather
// than an error, and a per-call rule is evaluated with the arguments of that call.

import test from 'node:test';
import assert from 'node:assert/strict';
import { dispatch } from '../app/src/pages/harness/loop/Dispatch.ts';
import type { DispatchSpec } from '../app/src/pages/harness/loop/Dispatch.ts';
import type { ToolCall } from '../app/src/pages/harness/loop/Types.ts';

function call(name: string, args: Record<string, Object>): ToolCall {
  return { id: 'c1', name: name, argumentsJson: JSON.stringify(args) } as ToolCall;
}

function spec(overrides: Partial<DispatchSpec>): DispatchSpec {
  return {
    handler: async (): Promise<string> => 'ran',
    ...overrides
  } as DispatchSpec;
}

test('a tool with no approval rule runs without asking', async () => {
  let asked = 0;
  const out = await dispatch(call('t', {}), () => spec({}), async (): Promise<boolean> => {
    asked++;
    return true;
  });
  assert.equal(out, 'ran');
  assert.equal(asked, 0);
});

test("a tool marked 'none' runs without asking", async () => {
  let asked = 0;
  const out = await dispatch(call('t', {}), () => spec({ approval: 'none' }),
    async (): Promise<boolean> => {
      asked++;
      return true;
    });
  assert.equal(out, 'ran');
  assert.equal(asked, 0);
});

test("'confirm' asks first and runs when allowed", async () => {
  let asked = 0;
  const out = await dispatch(call('t', { x: 1 }), () => spec({ approval: 'confirm' }),
    async (tool: string, detail: string): Promise<boolean> => {
      asked++;
      assert.equal(tool, 't');
      assert.equal(detail, '{"x":1}');
      return true;
    });
  assert.equal(out, 'ran');
  assert.equal(asked, 1);
});

test("'confirm' refused returns a tool result and never runs the handler", async () => {
  let ran = 0;
  const out = await dispatch(call('t', {}), () => spec({
    approval: 'confirm',
    handler: async (): Promise<string> => {
      ran++;
      return 'ran';
    }
  }), async (): Promise<boolean> => false);
  assert.equal(out, 'denied by user');
  assert.equal(ran, 0);
});

test('a per-call rule sees the arguments of that call', async () => {
  const seen: string[] = [];
  const rule = (args: Record<string, Object>): 'none' | 'confirm' => {
    return args['op'] === 'commit' ? 'confirm' : 'none';
  };
  await dispatch(call('git', { op: 'status' }), () => spec({ approval: rule }),
    async (): Promise<boolean> => {
      seen.push('asked');
      return true;
    });
  assert.deepEqual(seen, []);

  await dispatch(call('git', { op: 'commit' }), () => spec({ approval: rule }),
    async (): Promise<boolean> => {
      seen.push('asked');
      return true;
    });
  assert.deepEqual(seen, ['asked']);
});

test("'confirm' without an asker refuses rather than running unconfirmed", async () => {
  let ran = 0;
  const out = await dispatch(call('t', {}), () => spec({
    approval: 'confirm',
    handler: async (): Promise<string> => {
      ran++;
      return 'ran';
    }
  }));
  assert.equal(out.indexOf('no approval gate is installed') > 0, true);
  assert.equal(ran, 0);
});

test('an unknown tool is reported before anything else', async () => {
  const out = await dispatch(call('missing', {}), () => undefined);
  assert.equal(out, 'error: no such tool: missing');
});

test('unparsable arguments are reported without asking', async () => {
  let asked = 0;
  const bad = { id: 'c1', name: 't', argumentsJson: '{oops' } as ToolCall;
  const out = await dispatch(bad, () => spec({ approval: 'confirm' }),
    async (): Promise<boolean> => {
      asked++;
      return true;
    });
  assert.equal(out, 'error: arguments are not valid JSON');
  assert.equal(asked, 0);
});

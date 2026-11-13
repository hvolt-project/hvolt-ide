// One round's tool calls, run in order and recorded as they go.
//
// Pulled out of the turn loop because the recording rules are the part that has to survive a
// crash: a call is written down before it runs, so a later request can tell "never started" from
// "started, outcome unknown"; a call that never ran still gets a result row, so the model is not
// left looking at an unanswered call. Those rules are testable here without a transport, an event
// loop or a device.

import type { ToolCall } from './Types.ts';

/** Where the batch's results are written. The session implements this; tests stand in for it. */
export interface BatchRecorder {
  /** Recorded before the call runs. */
  noteToolCall(call: ToolCall, at: number): void;
  appendToolResult(callId: string, text: string, isError: boolean, at: number): void;
}

/** What the surface is told while the batch runs. */
export interface BatchSink {
  onToolStart(call: ToolCall): void;
  onToolResult(callId: string, text: string): void;
}

export interface BatchOutcome {
  /** Calls that ran and were recorded with their own result. */
  answered: number;
  /** True when the batch stopped early, so the results it wrote are not the whole round. */
  cancelled: boolean;
}

/** Runs one round's calls.
 *
 *  `invoke` returns the tool's text; a returned string starting with `error:` is recorded as a
 *  failed result. `cancelled` is read between calls, so a stop lands at a call boundary instead of
 *  in the middle of one. `now` is injected so the recording times are assertable.
 */
export async function runBatch(calls: ToolCall[], invoke: (call: ToolCall) => Promise<string>,
  recorder: BatchRecorder, sink: BatchSink, cancelled: () => boolean,
  now: () => number): Promise<BatchOutcome> {
  let answered = 0;
  const answeredIds: string[] = [];
  for (const call of calls) {
    if (cancelled()) {
      break;
    }
    sink.onToolStart(call);
    recorder.noteToolCall(call, now());
    const result = await invoke(call);
    recorder.appendToolResult(call.id, result, result.indexOf('error:') === 0, now());
    answered += 1;
    answeredIds.push(call.id);
    sink.onToolResult(call.id, result);
  }
  if (answered === calls.length) {
    return { answered: answered, cancelled: false };
  }
  const reason = cancelled()
    ? 'error: 用户中止，工具没有执行'
    : 'error: 这一轮在工具执行前结束，工具没有执行';
  for (const call of calls) {
    if (answeredIds.indexOf(call.id) >= 0) {
      continue;
    }
    recorder.noteToolCall(call, now());
    recorder.appendToolResult(call.id, reason, true, now());
  }
  return { answered: answered, cancelled: true };
}

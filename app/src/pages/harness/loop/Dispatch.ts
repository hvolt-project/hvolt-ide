// One tool call: parse its arguments, find the handler, run it, and turn every failure into text
// the model can read.
//
// The three failure shapes here — unknown tool, unparsable arguments, handler throwing — are the
// ones a turn meets in practice, and all three are decided without a device, so they are asserted
// in the local test run rather than discovered on the phone.

import type { ToolCall } from './Types.ts';

/** The parts of a tool the dispatcher needs. The registry supplies these. */
export interface DispatchSpec {
  handler: (args: Record<string, Object>) => Promise<string>;
}

export async function dispatch(call: ToolCall,
  lookup: (name: string) => DispatchSpec | undefined): Promise<string> {
  const spec: DispatchSpec | undefined = lookup(call.name);
  if (spec === undefined) {
    return 'error: no such tool: ' + call.name;
  }
  let args: Record<string, Object> = {};
  try {
    args = JSON.parse(call.argumentsJson) as Record<string, Object>;
  } catch (e) {
    return 'error: arguments are not valid JSON';
  }
  try {
    return await spec.handler(args);
  } catch (e) {
    return 'error: ' + (e as Error).message;
  }
}

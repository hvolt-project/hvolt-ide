// One tool call: parse its arguments, find the handler, run it, and turn every failure into text
// the model can read.
//
// The three failure shapes here — unknown tool, unparsable arguments, handler throwing — are the
// ones a turn meets in practice, and all three are decided without a device, so they are asserted
// in the local test run rather than discovered on the phone.
//
// Approval lives here rather than inside individual tools: a tool declares how it is approved and
// the dispatcher asks before running it, so a tool cannot silently skip the gate by forgetting to
// call it. The asker is injected, which keeps this file free of UI imports and testable on its own.

import type { ToolCall } from './Types.ts';

/** `none` runs straight away; `confirm` asks first. A function decides per call. */
export type ApprovalLevel = 'none' | 'confirm';
export type ApprovalRule = ApprovalLevel | ((args: Record<string, Object>) => ApprovalLevel);

/** Asks the person. Resolves false when they refuse; refusing is a tool result, not an error. */
export type ApprovalAsker = (tool: string, detail: string) => Promise<boolean>;

/** The parts of a tool the dispatcher needs. The registry supplies these. */
export interface DispatchSpec {
  handler: (args: Record<string, Object>) => Promise<string>;
  /** Absent means `none`: a tool that says nothing needs no confirmation. */
  approval?: ApprovalRule;
}

function resolveApproval(spec: DispatchSpec, args: Record<string, Object>): ApprovalLevel {
  const rule: ApprovalRule | undefined = spec.approval;
  if (rule === undefined) {
    return 'none';
  }
  if (typeof rule === 'string') {
    return rule;
  }
  return rule(args);
}

export async function dispatch(call: ToolCall,
  lookup: (name: string) => DispatchSpec | undefined,
  ask?: ApprovalAsker): Promise<string> {
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
  if (resolveApproval(spec, args) === 'confirm') {
    if (ask === undefined) {
      // No asker wired: refusing is safer than running unconfirmed, and it is what the old
      // device-side gate did before anyone installed it.
      return 'error: this tool needs confirmation but no approval gate is installed';
    }
    let allowed: boolean = false;
    try {
      allowed = await ask(call.name, call.argumentsJson);
    } catch (e) {
      return 'error: approval failed: ' + (e as Error).message;
    }
    if (!allowed) {
      return 'denied by user';
    }
  }
  try {
    return await spec.handler(args);
  } catch (e) {
    return 'error: ' + (e as Error).message;
  }
}

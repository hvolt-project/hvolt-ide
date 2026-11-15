// Model-authored JavaScript, executed on this device by QuickJS.
//
// QuickJS is linked into libnavi.so as a static archive: a separate shared library would add a
// DT_NEEDED edge that the package loader resolves before the module's own symbols, and when that
// resolution fails the whole native module (and with it the page) stops evaluating. Each call gets
// a fresh runtime, a memory limit and an interrupt handler that fires once at the deadline, so a
// runaway script returns an error instead of taking the app down.

import { ToolRegistry } from '../mcp/Registry';
import { jsEval, jsEvalAbort, jsEvalBegin, jsEvalResume } from 'libnavi.so';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['js_eval'];


/** 一次工具调用的结果，按 native 约定的形状回填。 */
interface ToolCallResult {
  id: number;
  result: string;
}

/**
 * 脚本里 `await tool(name, args)` 的落地。
 *
 * native 侧把执行切成「跑到挂起 → 交回待办调用 → 灌结果继续」几步，这里就是那个循环：
 * 每一步都同步返回一段状态 JSON，工具执行在 ArkTS 侧 await。会话有轮数上限与总超时，
 * 异常路径会 abort 掉 native 里的 runtime，不留悬挂会话。
 */
async function runWithTools(registry: ToolRegistry, code: string, timeoutMs: number,
  memoryMb: number): Promise<string> {
  let state = jsEvalBegin(code, timeoutMs, memoryMb);
  const deadline = Date.now() + timeoutMs;
  for (let round = 0; round < 32; round += 1) {
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(state) as Record<string, Object>;
    } catch (e) {
      // native 侧返回了非 JSON（内部异常或崩溃后的残片）：包成统一形状交回，不把解析错误
      // 抛到工具层外面。
      return JSON.stringify({ ok: false, error: 'js bridge returned non-JSON: ' + state.substring(0, 200) });
    }
    const status = parsed['status'] as string;
    if (status === 'done') {
      return JSON.stringify(parsed['result']);
    }
    if (status !== 'need') {
      // 与成功结果同一形状：调用方不该靠「有没有 status 字段」区分桥层失败与脚本失败。
      const message = parsed['message'] === undefined ? state : parsed['message'] as string;
      return JSON.stringify({ ok: false, error: message });
    }
    const session = parsed['session'] as number;
    if (Date.now() > deadline) {
      jsEvalAbort(session);
      return '{"ok":false,"error":"timeout while waiting for tools"}';
    }
    const calls = (parsed['calls'] === undefined ? [] : parsed['calls']) as Object[];
    const results: ToolCallResult[] = [];
    for (const raw of calls) {
      const call = raw as Record<string, Object>;
      const name = call['name'] as string;
      const callArgs = (call['args'] === undefined ? {} : call['args']) as Record<string, Object>;
      let out = '';
      try {
        const spec = registry.get(name);
        out = spec === undefined ? 'error: no such tool: ' + name : await spec.handler(callArgs);
      } catch (e) {
        out = 'error: ' + (e as Error).message;
      }
      results.push({ id: call['id'] as number, result: out });
    }
    state = jsEvalResume(session, JSON.stringify(results));
  }
  return '{"ok":false,"error":"too many tool rounds"}';
}

export function registerJsEvalTools(registry: ToolRegistry): void {
  registry.register({
    name: 'js_eval',
    description: 'Evaluate JavaScript on the device with QuickJS. The result is a JSON envelope '
      + '{ok, type, value, ms}: type is the JS typeof of the completion value, value is the value '
      + 'itself (objects and arrays arrive as JSON structures, not as an escaped string); '
      + 'undefined comes back as {__t: "undefined"}. Values JSON cannot carry are wrapped as '
      + '{__t: kind, v: text} with '
      + 'kind one of bigint, date, regexp, map, set, typedarray, circular-ref, truncated, '
      + 'undefined — so a Map is distinguishable from a plain object. Each call runs in a fresh '
      + 'context with no state carried over, a wall-clock deadline and a memory cap; syntax and '
      + 'runtime errors come back as ok:false instead of throwing. Use it for calculations and for '
      + 'checking what a snippet does, not for touching files (use sandbox_sh for that). A script '
      + 'may also call other tools: `const r = await tool("read", {path: "src/x.ets"})` returns '
      + 'that tool\'s text result. Scripts containing `tool(` or `await` must `return` their value '
      + '— the last-expression shorthand does not apply on that path.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'code': {
          'type': 'string',
          'description': 'JavaScript source. The completion value is returned, e.g. "1+2" gives 3.'
        },
        'why': {
          'type': 'string',
          'description': 'What this script will do and what goes wrong if it does something else — '
            + 'written for the person deciding whether to allow it, 20 to 200 characters. A '
            + 'restatement of the code is not enough: say the consequence.'
        },
        'timeout_ms': {
          'type': 'number',
          'description': 'Wall-clock deadline in milliseconds (default 5000, capped at 600000).'
        },
        'memory_mb': {
          'type': 'number',
          'description': 'Heap cap in megabytes (default 64).'
        }
      },
      'required': ['code', 'why']
    },
    // One confirmation per script, not per statement: the script is the unit the person is
    // agreeing to, and asking again inside it would be asking about something they already saw.
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const code = args['code'];
      if (code === undefined || code === null) {
        return Promise.resolve(JSON.stringify({ ok: false, error: 'code is required' }));
      }
      const whyArg = args['why'];
      const why = whyArg === undefined || whyArg === null ? '' : whyArg as string;
      // Checked here, before the approval gate: a missing or hollow `why` is a malformed call,
      // not a decision someone should be asked to make. Rejecting it in the handler means no
      // dialog appears for a call that could never run.
      if (why.length < 20 || why.length > 200) {
        // 与成功结果同一个形状：调用方不该靠「是否以 error: 开头」区分参数没通过和脚本跑完了。
        return Promise.resolve(JSON.stringify({
          ok: false,
          error: 'why must be 20-200 characters, got ' + why.length
            + ' — say what the script will do and what happens if it does something else'
        }));
      }
      const timeoutArg = args['timeout_ms'];
      const memoryArg = args['memory_mb'];
      const timeoutMs: number = timeoutArg === undefined || timeoutArg === null
        ? 5000 : Math.round(timeoutArg as number);
      const memoryMb: number = memoryArg === undefined || memoryArg === null
        ? 64 : Math.round(memoryArg as number);
      // 用到 tool() 或 await 时走带桥的分阶段执行；其余仍走一次跑完的同步路径（更快）。
      const source = code as string;
      if (source.indexOf('tool(') >= 0 || source.indexOf('await') >= 0) {
        return runWithTools(registry, source, timeoutMs, memoryMb);
      }
      return Promise.resolve(jsEval(source, timeoutMs, memoryMb));
    }
  });
}

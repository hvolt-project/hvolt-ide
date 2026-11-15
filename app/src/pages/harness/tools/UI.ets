// Driving the device's own interface.
//
// Every call here injects an input event into whatever is in front. That is irreversible in the
// sense that matters: the tap lands where the screen is, not where the model imagined. So each
// tool is marked confirm — the approval gate asks the person first, every time, unless they have
// allowed it for the session — and the description says plainly what it will do.

import { ToolRegistry } from '../mcp/Registry';
import { FileContext } from './Files';
import { ToolRun, runHvolt } from './Build';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['tap', 'swipe', 'input_text', 'key_event'];


function lastLines(text: string, lines: number): string {
  const all: string[] = text.split('\n');
  const start = all.length > lines ? all.length - lines : 0;
  return all.slice(start).join('\n');
}

/** One uitest input command through the device shell. */
function inject(command: string, ctx: FileContext): Promise<string> {
  return runHvolt(['shell', command], ctx.projectDir()).then((run: ToolRun) => {
    return 'exit ' + run.code + '\n' + lastLines(run.output, 20);
  });
}

export function registerUiTools(registry: ToolRegistry, ctx: FileContext): void {
  registry.register({
    name: 'tap',
    description: 'Tap the screen at one point, in device pixels. Injects a real touch event into '
      + 'whatever is in front; it cannot be undone.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'x': { 'type': 'number', 'description': 'Horizontal position in pixels.' },
        'y': { 'type': 'number', 'description': 'Vertical position in pixels.' }
      },
      'required': ['x', 'y']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const x = Math.round(args['x'] as number);
      const y = Math.round(args['y'] as number);
      if (x < 0 || y < 0) {
        return Promise.resolve('error: coordinates must not be negative');
      }
      return inject('uitest uiInput click ' + x + ' ' + y, ctx);
    }
  });

  registry.register({
    name: 'swipe',
    description: 'Swipe from one point to another, in device pixels, over a given duration. '
      + 'Injects a real touch gesture; it cannot be undone.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'fromX': { 'type': 'number' },
        'fromY': { 'type': 'number' },
        'toX': { 'type': 'number' },
        'toY': { 'type': 'number' },
        'durationMs': { 'type': 'number', 'description': 'Gesture duration; default 300.' }
      },
      'required': ['fromX', 'fromY', 'toX', 'toY']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const fx = Math.round(args['fromX'] as number);
      const fy = Math.round(args['fromY'] as number);
      const tx = Math.round(args['toX'] as number);
      const ty = Math.round(args['toY'] as number);
      const raw = args['durationMs'];
      const ms = raw === undefined ? 300 : Math.round(raw as number);
      return inject('uitest uiInput swipe ' + fx + ' ' + fy + ' ' + tx + ' ' + ty + ' ' + ms, ctx);
    }
  });

  registry.register({
    name: 'input_text',
    description: 'Type text into the focused field. Injects keystrokes; it cannot be undone.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': { 'type': 'string', 'description': 'Text to type.' }
      },
      'required': ['text']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const text = args['text'] as string;
      if (text.length === 0) {
        return Promise.resolve('error: text is required');
      }
      // The device shell splits on spaces, so the payload is single-quoted and its quotes escaped.
      const quoted = "'" + text.replace(/'/g, "'\\''") + "'";
      return inject('uitest uiInput text ' + quoted, ctx);
    }
  });

  registry.register({
    name: 'key_event',
    description: 'Send one key press to the device, e.g. 2054 for back or 2055 for home.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'code': { 'type': 'number', 'description': 'HarmonyOS key code.' }
      },
      'required': ['code']
    },
    approval: 'confirm',
    handler: (args: Record<string, Object>): Promise<string> => {
      const code = Math.round(args['code'] as number);
      return inject('uitest uiInput keyEvent ' + code, ctx);
    }
  });
}

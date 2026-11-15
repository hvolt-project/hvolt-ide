// ide: drive what the editor shows, never what it holds.
//
// This is a presentation tool. Everything here moves the face, the open file, the cursor, the
// selection or the scroll offset, and reads them back; not one action writes a file or changes
// the text. Real content changes go through write / edit / apply_patch, which is why every
// action here is approval `none` — a call that cannot change state has nothing to confirm.
//
// `run` and `insert` are deliberately absent: building and deploying are their own tools, and
// typing into the buffer is a content change wearing a cursor's clothes.

import { ToolRegistry } from '../mcp/Registry';
import { ideController, ideSession, ideSwitchFace } from '../../model/IdeBus';

/** 暴露给 MCP 的工具名；自动注册表按这个导出决定是否收录本文件。 */
export const MCP_EXPOSE: string[] = ['ide'];

function argText(args: Record<string, Object>, key: string): string {
  const value = args[key];
  return value === undefined || value === null ? '' : value as string;
}

function argNumber(args: Record<string, Object>, key: string, fallback: number): number {
  const value = args[key];
  return typeof value === 'number' ? value as number : fallback;
}

/** The page answers every one of these with `true`, `false` or the state JSON. */
function ask(script: string): Promise<string> {
  const controller = ideController();
  if (controller === undefined) {
    return Promise.resolve('error: the page has not bound its session yet');
  }
  return controller.runJavaScript(script).then((answer: string) => {
    return answer;
  }).catch((e: Error) => {
    return 'error: ' + e.message;
  });
}

export function registerIdeTools(registry: ToolRegistry): void {
  registry.register({
    name: 'ide',
    description: 'Show and read the editor: switch face (ide | harness), open a file, move the '
      + 'cursor, set the selection, scroll to a line, read editor state. It never changes file '
      + 'contents or the project; use write / edit for that.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['face', 'open', 'cursor', 'select', 'scroll', 'state'],
          'description': 'What to do on the editor surface.'
        },
        'face': {
          'type': 'string',
          'enum': ['ide', 'harness'],
          'description': 'face: which side to turn to. `ide` is the editor, `harness` the chat.'
        },
        'path': {
          'type': 'string',
          'description': 'open: project-relative file to show.'
        },
        'line': {
          'type': 'number',
          'description': 'cursor / scroll: 1-based line. Defaults to the current line for cursor.'
        },
        'column': {
          'type': 'number',
          'description': 'cursor: 1-based column. Defaults to 1.'
        },
        'toLine': {
          'type': 'number',
          'description': 'select: 1-based end line.'
        },
        'toColumn': {
          'type': 'number',
          'description': 'select: 1-based end column.'
        }
      },
      'required': ['action']
    },
    approval: 'none',
    handler: (args: Record<string, Object>): Promise<string> => {
      const action = argText(args, 'action');
      if (action === 'face') {
        const which = argText(args, 'face');
        const harness = which !== 'ide';
        if (!ideSwitchFace(harness)) {
          return Promise.resolve('error: the page has not bound its session yet');
        }
        return Promise.resolve('face: ' + (harness ? 'harness' : 'ide'));
      }
      if (action === 'open') {
        const rel = argText(args, 'path');
        if (rel.length === 0) {
          return Promise.resolve('error: path is empty');
        }
        const session = ideSession();
        if (session === undefined) {
          return Promise.resolve('error: the page has not bound its session yet');
        }
        // Same entry point a tap on the file list uses, so the unsaved-buffer rule and the
        // tab bookkeeping stay in one place.
        session.openFile(rel);
        return Promise.resolve('opened ' + rel);
      }
      if (action === 'cursor') {
        const line = argNumber(args, 'line', 0);
        const column = argNumber(args, 'column', 0);
        if (line <= 0) {
          return ask('hvoltState()').then((state: string) => {
            return 'error: line must be 1 or greater\n' + state;
          });
        }
        return ask('hvoltCursor(' + line + ', ' + (column <= 0 ? 1 : column) + ')')
          .then((answer: string) => 'cursor: ' + answer);
      }
      if (action === 'select') {
        const fromLine = argNumber(args, 'line', 0);
        const fromColumn = argNumber(args, 'column', 0);
        const toLine = argNumber(args, 'toLine', 0);
        const toColumn = argNumber(args, 'toColumn', 0);
        if (fromLine <= 0 || toLine <= 0) {
          return Promise.resolve('error: select needs line and toLine, both 1 or greater');
        }
        const script = 'hvoltSelect(' + fromLine + ', ' + (fromColumn <= 0 ? 1 : fromColumn)
          + ', ' + toLine + ', ' + (toColumn <= 0 ? 1 : toColumn) + ')';
        return ask(script).then((answer: string) => 'select: ' + answer);
      }
      if (action === 'scroll') {
        const line = argNumber(args, 'line', 0);
        if (line <= 0) {
          return Promise.resolve('error: scroll needs a line, 1 or greater');
        }
        return ask('hvoltScroll(' + line + ')').then((answer: string) => 'scroll: ' + answer);
      }
      if (action === 'state') {
        return ask('hvoltState()');
      }
      return Promise.resolve('error: unknown action `' + action + '`');
    }
  });
}

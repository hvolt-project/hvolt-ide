// Turning the flat transcript into what the eye should see.
//
// Every thought and tool line is "process": the middle of a turn, not its answer. Consecutive
// process lines form one block, and four display modes decide whether that block starts open.
// The final answer and the closing statistic are never folded — folding exists to hide how the
// work was done, never what came of it.

export type FoldMode = 'quiet' | 'normal' | 'detail' | 'full';

export type ChatKind = 'user' | 'assistant' | 'tool' | 'error' | 'thought' | 'stats';

export interface ChatLine {
  kind: ChatKind;
  text: string;
  /** Tool name, for tool lines. */
  name: string;
}

export interface ChatBlock {
  kind: 'user' | 'assistant' | 'stats' | 'group';
  /** Set for non-group blocks. */
  text: string;
  /** Whether a group starts open. Ignored by other kinds. */
  open: boolean;
  items: ChatLine[];
  /** The one line a collapsed group shows. */
  summary: string;
  key: string;
}

function isProcess(kind: ChatKind): boolean {
  return kind === 'thought' || kind === 'tool';
}

function firstLine(text: string): string {
  const cut = text.indexOf('\n');
  const head = cut >= 0 ? text.substring(0, cut) : text;
  return head.length > 48 ? head.substring(0, 48) + '…' : head;
}

/** What a collapsed group says: one line, chosen by how much the mode is willing to spend. */
export function groupSummary(items: ChatLine[], mode: FoldMode): string {
  let thoughts = 0;
  let tools = 0;
  let lastTool = '';
  let preview = '';
  for (const item of items) {
    if (item.kind === 'thought') {
      thoughts++;
      if (preview.length === 0) {
        preview = firstLine(item.text);
      }
    } else if (item.kind === 'tool') {
      tools++;
      if (item.name.length > 0) {
        lastTool = item.name;
      }
    }
  }
  const steps = items.length;
  if (mode === 'quiet') {
    return '过程 · ' + steps + ' 步';
  }
  // normal keeps the shape of the work visible: what was being thought, what ran last.
  const parts: string[] = [];
  if (thoughts > 0) {
    parts.push(preview.length > 0 ? preview : '思考');
  }
  if (tools > 0) {
    parts.push(lastTool.length > 0 ? lastTool : '工具');
  }
  const body = parts.join(' · ');
  return (body.length > 0 ? body + '  ' : '') + '· ' + steps + ' 步';
}

/**
 * Splits lines into blocks for rendering.
 *
 * `toggled` holds the user's own open/closed decisions, keyed by block key; a key that is present
 * wins over the mode default, so switching modes does not undo what the reader did by hand.
 */
export function buildBlocks(lines: ChatLine[], mode: FoldMode, toggled: Map<string, boolean>): ChatBlock[] {
  const blocks: ChatBlock[] = [];
  let pending: ChatLine[] = [];

  const flush = () => {
    if (pending.length === 0) {
      return;
    }
    const key = 'g' + blocks.length;
    const byMode = mode === 'detail' || mode === 'full';
    const open = toggled.has(key) ? toggled.get(key) as boolean : byMode;
    blocks.push({
      kind: 'group', text: '', open: open, items: pending,
      summary: groupSummary(pending, mode), key: key
    });
    pending = [];
  };

  for (const line of lines) {
    if (isProcess(line.kind)) {
      pending.push(line);
      continue;
    }
    flush();
    blocks.push({
      kind: line.kind === 'user' ? 'user' : (line.kind === 'stats' ? 'stats' : 'assistant'),
      text: line.text, open: true, items: [], summary: '',
      key: 'b' + blocks.length
    });
  }
  flush();
  return blocks;
}

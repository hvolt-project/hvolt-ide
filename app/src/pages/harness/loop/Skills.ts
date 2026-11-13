// Skill catalog: what the model is told it can load, and the one message that says it.
//
// The catalog is a single message in the conversation, not a paragraph of the system prompt. Two
// reasons: the system prompt is the cached prefix and must stay byte-identical between turns, and
// a skill can appear or change at any moment — a message can be replaced in place, a prefix cannot
// be edited without invalidating everything after it.
//
// Replacement, not append. A session that gained ten skills should not carry ten catalogs.

export interface SkillEntry {
  /** Directory name; the name the model passes to the skill tool. */
  name: string;
  /** One line from the frontmatter; what the model matches a task against. */
  description: string;
  /** 'builtin' ships with the app and cannot change; 'workspace' is writable. */
  source: string;
}

/** Marks catalog messages so they can be found and replaced rather than searched for by luck. */
export const CATALOG_MARK: string = 'A skill is a reusable set of task-specific instructions.';

export interface Frontmatter {
  meta: Map<string, string>;
  body: string;
}

/**
 * Splits `---` frontmatter from the body. A file without frontmatter keeps its whole text as the
 * body, which is what an older or hand-written skill looks like.
 */
export function parseFrontmatter(text: string): Frontmatter {
  const meta = new Map<string, string>();
  const trimmed = text.trimStart();
  if (!trimmed.startsWith('---')) {
    return { meta: meta, body: text };
  }
  const close = trimmed.indexOf('\n---', 3);
  if (close < 0) {
    return { meta: meta, body: text };
  }
  const header = trimmed.substring(3, close);
  for (const line of header.split('\n')) {
    const colon = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    const key = line.substring(0, colon).trim();
    const value = line.substring(colon + 1).trim();
    if (key.length > 0) {
      meta.set(key, value);
    }
  }
  const bodyStart = trimmed.indexOf('\n', close + 1);
  const body = bodyStart < 0 ? '' : trimmed.substring(bodyStart + 1);
  return { meta: meta, body: body };
}

/**
 * One skill from its file text. The directory name is the fallback when the frontmatter has none,
 * so a folder of plain markdown still works.
 */
export function parseSkill(dirName: string, text: string, source: string): SkillEntry {
  const parsed = parseFrontmatter(text);
  const named = parsed.meta.get('name');
  const described = parsed.meta.get('description');
  let description = described === undefined ? '' : described;
  if (description.length === 0) {
    // First non-empty line of the body, so a skill without frontmatter is still describable.
    for (const line of parsed.body.split('\n')) {
      if (line.trim().length > 0) {
        description = line.trim();
        break;
      }
    }
  }
  return {
    name: named === undefined || named.length === 0 ? dirName : named,
    description: description,
    source: source
  };
}

/** A stable digest of what the catalog says, for deciding whether the message needs replacing. */
export function catalogFingerprint(entries: SkillEntry[]): string {
  const parts: string[] = [];
  for (const entry of entries) {
    parts.push(entry.name + '\u0000' + entry.description + '\u0000' + entry.source);
  }
  parts.sort();
  return parts.join('\u0001');
}

/** The catalog message body. Empty when there are no skills, which removes the message entirely. */
export function catalogText(entries: SkillEntry[]): string {
  if (entries.length === 0) {
    return '';
  }
  const lines: string[] = [];
  lines.push('<system-reminder>');
  lines.push(CATALOG_MARK);
  lines.push('');
  lines.push('<available_skills>');
  const sorted: SkillEntry[] = entries.slice();
  sorted.sort((a: SkillEntry, b: SkillEntry): number => {
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  });
  for (const entry of sorted) {
    const source = entry.source === 'builtin' ? '' : ' [' + entry.source + ']';
    lines.push('- `' + entry.name + '`' + source + ': ' + entry.description);
  }
  lines.push('</available_skills>');
  lines.push('');
  lines.push('If the user names a skill, or the task clearly matches one, call the `skill` tool with ' +
    'the exact name before acting. This catalog carries summaries only; do not follow a skill until ' +
    'it has been loaded.');
  lines.push('</system-reminder>');
  return lines.join('\n');
}

/** Whether a message is the catalog rather than something the person said. */
export function isCatalog(text: string): boolean {
  return text.indexOf(CATALOG_MARK) >= 0;
}

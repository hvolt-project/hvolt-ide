// Completion for the composer: `/` for commands, `@` for project files.
//
// The rules are small but the edges matter — a second `@`, a trailing space that ends the token,
// a command that matches itself exactly, and case-insensitive file matching. Held here so they can
// be exercised without a device.

export interface Suggestion {
  /** 'cmd' or 'file'; empty when nothing is being completed. */
  kind: string;
  items: string[];
}

export const COMMANDS: string[] = ['/reset', '/compact', '/skills', '/help'];

const MAX_FILES = 8;

/** What the composer should offer for the current draft. */
export function suggestFor(draft: string, files: string[]): Suggestion {
  const text = draft.trimStart();
  if (text.startsWith('/')) {
    const typed = text.toLowerCase();
    // An exact match is dropped: offering the command already typed is noise.
    const matched = COMMANDS.filter((c: string) => c.startsWith(typed) && c !== typed);
    return { kind: 'cmd', items: matched };
  }
  const at = text.lastIndexOf('@');
  if (at >= 0) {
    const token = text.substring(at);
    // A space after the @ means the file token is finished.
    if (token.indexOf(' ') < 0) {
      const typed = token.substring(1).toLowerCase();
      const matched = files.filter((f: string) => f.toLowerCase().includes(typed));
      return { kind: 'file', items: matched.slice(0, MAX_FILES) };
    }
  }
  return { kind: '', items: [] };
}

/** The draft with a suggestion accepted. Commands replace the whole field; a file replaces the
 *  token from its `@` to the end and leaves the rest of the message intact. */
export function applySuggestion(draft: string, kind: string, item: string): string {
  if (kind === 'cmd') {
    return item;
  }
  const at = draft.lastIndexOf('@');
  if (at < 0) {
    return draft + item;
  }
  return draft.substring(0, at) + '@' + item + ' ';
}

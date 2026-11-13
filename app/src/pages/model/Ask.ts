// Questions asked by the model, and the answers it gets back.
//
// The shapes follow the harness this application mirrors: a call carries a group of questions, each
// with an id that the answers come back on; an option is a label plus the reason to pick it, so the
// model can state a trade-off instead of a bare word; and an answer is a set of labels plus optional
// free text, which is how both "pick one" and "pick several, and here is why" fit one reply.
//
// Pure so the formatting and parsing run under `node --test` without a device.

export interface AskOption {
  label: string;
  description: string;
}

export interface AskQuestion {
  /** Unique within one call; the answer names it back. */
  id: string;
  question: string;
  header: string;
  options: AskOption[];
  multiSelect: boolean;
}

export interface AskAnswer {
  id: string;
  /** Chosen labels, in the order they were shown. Empty when the question was skipped. */
  selected: string[];
  /** Free text: a reason, a correction, or the whole answer when no option fit. */
  custom: string;
}

/** One answer per question, in the shape the tool result carries. */
export function formatAnswers(answers: AskAnswer[]): string {
  const items: string[] = [];
  for (const answer of answers) {
    const labels: string[] = [];
    for (const label of answer.selected) {
      labels.push(JSON.stringify(label));
    }
    let item = '{"id":' + JSON.stringify(answer.id) + ',"selected":[' + labels.join(',') + ']';
    if (answer.custom.length > 0) {
      item += ',"custom":' + JSON.stringify(answer.custom);
    }
    item += '}';
    items.push(item);
  }
  return '{"answers":[' + items.join(',') + ']}';
}

/** The reply when the wait ended before anyone answered. */
export function formatPending(callId: string): string {
  return '{"pending":true,"callId":' + JSON.stringify(callId) + '}';
}

/** Progress label for the panel: which question of how many. */
export function progressLabel(index: number, total: number): string {
  if (total <= 1) {
    return '';
  }
  return (index + 1) + '/' + total;
}

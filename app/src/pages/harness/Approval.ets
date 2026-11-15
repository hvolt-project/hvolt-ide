// Approval gate for irreversible tools.
//
// Three answers, because "once" and "for this session" are different promises: the first keeps
// the gate in the loop for the next call, the second stops asking. Denying returns to the model
// as a tool result, never as a thrown error, so it can adapt instead of retrying blindly.

import hilog from '@ohos.hilog';
import promptAction from '@ohos.promptAction';

export type ApprovalAnswer = 'once' | 'session' | 'deny';

interface PendingChoice {
  resolve: (answer: ApprovalAnswer) => void;
}

export class ApprovalGate {
  /** Tools the user allowed for the rest of this app session. */
  private allowed: Set<string> = new Set();
  private queue: PendingChoice[] = [];

  approveForSession(tool: string): void {
    this.allowed.add(tool);
  }

  reset(): void {
    this.allowed.clear();
  }

  isAllowedForSession(tool: string): boolean {
    return this.allowed.has(tool);
  }

  /** Resolves with the user's answer; session approvals short-circuit without a dialog. */
  async request(tool: string, detail: string): Promise<boolean> {
    if (this.allowed.has(tool)) {
      return true;
    }
    hilog.info(0x0000, 'hvoltide', 'approval requested: %{public}s %{public}s', tool,
      detail.substring(0, 120));
    const answer = await this.ask(tool, detail);
    if (answer === 'session') {
      this.allowed.add(tool);
      return true;
    }
    return answer === 'once';
  }

  private ask(tool: string, detail: string): Promise<ApprovalAnswer> {
    const buttons: promptAction.Button[] = [
      { text: '拒绝', color: '#E5484D' },
      { text: '本次允许', color: '#1F6FEB' },
      { text: '本会话允许', color: '#1F6FEB' }
    ];
    const options: promptAction.ShowDialogOptions = {
      title: '需要确认：' + tool,
      message: formatDetail(detail),
      buttons: buttons
    };
    return promptAction.showDialog(options).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        return 'once' as ApprovalAnswer;
      }
      if (result.index === 2) {
        return 'session' as ApprovalAnswer;
      }
      return 'deny' as ApprovalAnswer;
    }).catch((e: Error) => {
      hilog.warn(0x0000, 'hvoltide', 'approval dialog failed: %{public}s', e.message);
      return 'deny' as ApprovalAnswer;
    });
  }
}

/**
 * 把工具参数摊成给人读的几行。
 *
 * 参数是 JSON 文本；原样塞进对话框时，模型写的那段说明（`why`）会跟括号引号搅在一起，
 * 读者要在转义符里找「这次调用会造成什么」。所以：模型的说明放最前面空一行，其余键每行一个，
 * 值过长截断。解析失败才退回原文——退路只在参数本身不是 JSON 时用到。
 */
function formatDetail(detail: string): string {
  let parsed: Record<string, Object>;
  try {
    parsed = JSON.parse(detail) as Record<string, Object>;
  } catch (e) {
    return detail.length > 240 ? detail.substring(0, 240) + '…' : detail;
  }
  if (parsed === null || typeof parsed !== 'object') {
    return detail.length > 240 ? detail.substring(0, 240) + '…' : detail;
  }
  const lines: string[] = [];
  const why = parsed['why'];
  if (typeof why === 'string' && (why as string).length > 0) {
    lines.push(why as string);
    lines.push('');
  }
  for (const key of Object.keys(parsed)) {
    if (key === 'why') {
      continue;
    }
    const value = parsed[key];
    let text = '';
    if (typeof value === 'string') {
      text = value as string;
    } else {
      text = JSON.stringify(value);
    }
    const oneLine = text.length > 160 ? text.substring(0, 160) + '…' : text;
    lines.push(key + '：' + oneLine);
  }
  const joined = lines.join('\n');
  return joined.length > 600 ? joined.substring(0, 600) + '…' : joined;
}

export const APPROVAL: ApprovalGate = new ApprovalGate();

/**
 * The dispatcher reads `APPROVAL` directly, so there is nothing left to wire. Kept as a no-op
 * because `startHarness()` calls it at startup and the call site documents that approval is
 * installed before any tool can run.
 */
export function installApprovalGate(): void {
}

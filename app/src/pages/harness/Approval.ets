// Approval gate for irreversible tools.
//
// Three answers, because "once" and "for this session" are different promises: the first keeps
// the gate in the loop for the next call, the second stops asking. Denying returns to the model
// as a tool result, never as a thrown error, so it can adapt instead of retrying blindly.

import hilog from '@ohos.hilog';
import promptAction from '@ohos.promptAction';
import { setApprovalGate } from './tools/Device';

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
      message: detail.length > 240 ? detail.substring(0, 240) + '…' : detail,
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

export const APPROVAL: ApprovalGate = new ApprovalGate();

/** Wires the gate into the device tools. Call once before starting the endpoint. */
export function installApprovalGate(): void {
  setApprovalGate((tool: string, detail: string) => {
    return APPROVAL.request(tool, detail);
  });
}

// 输入区右侧那个键的行为。
//
// 一个键两种含义：回合在跑且输入框为空时是「终止」；输入框一旦有字就立刻变回「发送」，
// 而此时发送的含义是「打断并插话」。判定单独放在这里，是为了它能被测试钉住——
// 放在组件里就只能靠手点验证了。

export type ComposerAction = 'stop' | 'send';

/** 按下右侧键会发生什么。 */
export function composerAction(busy: boolean, draft: string): ComposerAction {
  if (busy && draft.trim().length === 0) {
    return 'stop';
  }
  return 'send';
}

/** 这次发送要不要先打断正在跑的回合。 */
export function interruptsTurn(busy: boolean): boolean {
  return busy;
}

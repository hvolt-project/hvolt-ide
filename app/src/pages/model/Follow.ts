// 「跟到底部还是停在原处」这一条行为，主对话列表和展开的过程组都要用同一套。
//
// 规则只有两句话：
//   1) 只有手指的滚动能改变跟随状态——程序自己滚到底也会触发滚动事件，那不是读者的意图；
//   2) 手指起手就停止跟随（拖动过程中新内容还在到），抬手时若停在底部则恢复跟随。
//
// 放在这里是为了它能被测试钉住：这段逻辑写错时的表现是「上翻一次以后就再也回不到底部」
// 或者「新内容一来就把人拽回底部」，两种都很难靠手点复现。

export class FollowBottom {
  private following: boolean = true;
  private programmatic: boolean = false;
  private userScrolling: boolean = false;

  /** 现在是否应该跟着内容走。 */
  follows(): boolean {
    return this.following;
  }

  /** 程序即将自己滚：滚到底之前先标记，免得把自己的滚动当成读者的。 */
  beginProgrammatic(): void {
    this.programmatic = true;
  }

  endProgrammatic(): void {
    this.programmatic = false;
  }

  /** 滚动开始。 */
  onScrollStart(): void {
    if (this.programmatic) {
      return;
    }
    this.userScrolling = true;
    this.following = false;
  }

  /** 滚动停下；atEnd 由调用方用具体控件判断（列表看 isAtEnd，组看是否触底）。 */
  onScrollStop(atEnd: boolean): void {
    if (this.programmatic) {
      this.userScrolling = false;
      return;
    }
    if (this.userScrolling) {
      this.following = atEnd;
    }
    this.userScrolling = false;
  }

  /** 读过的内容被清空（如清空对话）时回到跟随。 */
  reset(): void {
    this.following = true;
    this.programmatic = false;
    this.userScrolling = false;
  }
}

import { curves } from '@kit.ArkUI';

// One spring for every pane transition, so panes never disagree about motion.
export const DURATION: number = 280;

export function spring(): curves.ICurve {
  return curves.springMotion(0.36, 0.92);
}

// 翻面不是弹簧振荡，是两段：先快速冲过落点一点，再从过冲点沿一条长尾减速曲线慢慢
// 归位。第二段不做回摆，只是单向慢下来，所以看到的是「撞到位、被缓住、慢慢贴合」。
// 一段弹簧曲线做不到这个：它的回摆是递减振荡，而这里要的是过冲后的一次性慢回弹。
export const TURN_OVERSHOOT: number = 8;
export const TURN_SHOOT_MS: number = 190;
export const TURN_SETTLE_MS: number = 640;

// A face turn is half a revolution, and a drag maps one screen width onto it 1:1.
export const TURN: number = 180;
// 显隐切换点：转过 90° 就是背面，换面落在这条薄边上，看不出跳变。
export const TURN_VISIBLE: number = TURN / 2;
// 判定换面：手指滑到屏宽的三成即算过，不到则回弹。比视觉切换点低得多，因为手指走过的
// 路程与「看起来翻了多少」不是一回事——按半屏宽判，手感像怎么划都不动。
export const TURN_DECIDE: number = TURN * 0.3;
// The only finger counts that turn a face. Fewer collide with the editor's own pinch and
// pan; more is a system gesture and must not be answered.
export const TURN_FINGERS_MIN: number = 3;
export const TURN_FINGERS_MAX: number = 4;

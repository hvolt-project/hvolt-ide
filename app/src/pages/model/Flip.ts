import { TURN, TURN_DECIDE, TURN_FINGERS_MAX, TURN_FINGERS_MIN } from './Motion';

// 翻面的全部判定规则。三条都只跟角度和手指有关，与组件状态无关，所以放在这里：
// 页面里只剩「什么时候调用它们」，读代码时不用在动画与手势之间来回找条件。

/** 三到四指才接管：其它手指数留给编辑器与系统手势。 */
export function flipsArmable(fingers: number): boolean {
  return fingers >= TURN_FINGERS_MIN && fingers <= TURN_FINGERS_MAX;
}

/**
 * 跟手角度：位移按屏宽映射成 180°，永远从这次起手的基准算起，不做累加。
 * 从 IDE 面进入时方向由手指定；已经在 harness 面时任意滑向都朝 0 走。
 */
export function dragAngle(base: number, offsetX: number, width: number): number {
  const w: number = width > 0 ? width : 360;
  const travel: number = (Math.abs(offsetX) / w) * TURN;
  let next: number = base;
  if (Math.abs(base) <= 1) {
    next = offsetX < 0 ? -travel : travel;
  } else {
    next = base + (base > 0 ? -travel : travel);
  }
  if (next > TURN) {
    next = TURN;
  }
  if (next < -TURN) {
    next = -TURN;
  }
  return next;
}

/**
 * 松手落点：按这次手指走过的路程判，不按离 0 还有多远——后者会让退出要多走
 * 180°−阈值，进出手感差三倍。走够阈值就换面，不够就回弹到基准。
 */
export function releaseTarget(base: number, angle: number): number {
  const moved: number = Math.abs(angle - base);
  if (moved < TURN_DECIDE) {
    return base;
  }
  if (Math.abs(base) <= 1) {
    return angle < 0 ? -TURN : TURN;
  }
  return 0;
}

/** 不跟手的整段翻：已经在 harness 面就退回 IDE 面，否则按滑向翻过去。 */
export function directedTarget(angle: number, dir: number): number {
  if (Math.abs(angle) > 1) {
    return 0;
  }
  return dir < 0 ? -TURN : TURN;
}

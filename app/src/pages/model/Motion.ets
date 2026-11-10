import { curves } from '@kit.ArkUI';

// One spring for every pane transition, so panes never disagree about motion.
export const DURATION: number = 280;

export function spring(): curves.ICurve {
  return curves.springMotion(0.36, 0.92);
}

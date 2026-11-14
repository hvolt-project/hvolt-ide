import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';

/**
 * 窗口那一侧的三件事：屏幕尺寸、面高、状态条颜色。它们都属于窗口而不是布局，
 * 所以放在这里；页面只负责在旋转、改主题时调一次。
 */

export class ScreenSize {
  w: number = 0;
  h: number = 0;
}

/** 屏幕的 vp 尺寸。取不到时返回 0，由调用方当成「还不知道」。 */
export function measureScreen(): ScreenSize {
  const size = new ScreenSize();
  try {
    const d = display.getDefaultDisplaySync();
    size.w = px2vp(d.width);
    size.h = px2vp(d.height);
  } catch (e) {
    size.w = 0;
    size.h = 0;
  }
  return size;
}

/**
 * 面高：物理屏高减状态栏。不能写 '100%'——它参照的是页面布局盒，而布局盒已被系统按
 * 底部避让裁掉一条，面会停在手势条上沿，底下露出窗口底色。
 */
export function frameHeight(screenH: number, topInset: number): string | number {
  return screenH > 0 ? screenH - topInset : '100%';
}

/** 状态条那片属于窗口，不走页面内 padding：颜色直接设到窗口上。 */
export async function paintStatusBar(ctx: common.UIAbilityContext, bg: string,
  lightContent: boolean): Promise<void> {
  try {
    const win = await window.getLastWindow(ctx);
    await win.setWindowSystemBarProperties({
      statusBarColor: bg,
      statusBarContentColor: lightContent ? '#F3F5F7' : '#111827'
    });
  } catch (e) {
    console.error('status bar: ' + JSON.stringify(e));
  }
}

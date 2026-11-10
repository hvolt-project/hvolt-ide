import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

// The page owns layout inside the insets; the ability only reports where they are.
// Each edge reports its own height — taking the max of both for both keys put the
// status-bar value on the bottom edge and left the dock short by that difference.
function publishInsets(win: window.Window): void {
  try {
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    const top = px2vp(sys.topRect.height);
    const bottom = px2vp(Math.max(sys.bottomRect.height, nav.bottomRect.height));
    hilog.info(DOMAIN, 'testTag', '%{public}s',
      'insets top=' + top + ' bottom=' + bottom + ' nav=' + px2vp(nav.bottomRect.height));
    AppStorage.setOrCreate('topRectHeight', top);
    AppStorage.setOrCreate('bottomRectHeight', bottom);
  } catch (e) {
    hilog.error(DOMAIN, 'testTag', 'inset read failed');
  }
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // The shell renders a dark palette, so the app declares dark: the system then
    // draws the status bar dark instead of leaving a white strip above the chrome.
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'colorMode set failed');
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    let win: window.Window | undefined = undefined;
    try {
      win = windowStage.getMainWindowSync();
      this.armFullScreen(win);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'window chrome failed');
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // Avoid areas only carry real heights once the window is laid out: read during
      // onWindowStageCreate they are all zero, and the page then pads nothing.
      if (win !== undefined) {
        const w = win;
        setTimeout(() => {
          publishInsets(w);
        }, 300);
        w.on('avoidAreaChange', () => {
          publishInsets(w);
        });
      }
    });
  }

  // The shell keeps the status bar visible and paints its colour as the chrome colour,
  // so the top edge reads as one surface. Layout-fullscreen is left alone: on this
  // device it neither moved the page's origin nor let the app paint the strip, it only
  // made the bar transparent and the strip fell back to the window background.
  private armFullScreen(win: window.Window): void {
    // Drop the navigation bar: its white indicator strip is the only part of the
    // bottom edge the app cannot paint over. The page still pads its dock by the
    // reported inset, so the content stays above the gesture area.
    win.setWindowSystemBarEnable(['status']);
    win.setWindowSystemBarProperties({
      statusBarColor: '#FF131820',
      statusBarContentColor: '#FFFFFFFF'
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}

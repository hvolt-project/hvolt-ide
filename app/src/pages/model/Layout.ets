import mediaquery from '@ohos.mediaquery';
import { Bp } from './Bridge';
import { mark } from './Util';

// One place answers "what does the system say": colour mode and width class.
// `config.colorMode` reports NOT_SET on this device, so dark mode comes from the
// media query, which also fires when the user flips it.
export class LayoutWatcher {
  private compactL: mediaquery.MediaQueryListener | undefined = undefined;
  private mediumL: mediaquery.MediaQueryListener | undefined = undefined;
  private wideL: mediaquery.MediaQueryListener | undefined = undefined;
  private darkL: mediaquery.MediaQueryListener | undefined = undefined;
  private onBp: (bp: Bp) => void = () => {
  };
  private onDark: (dark: boolean) => void = () => {
  };

  constructor(onBp: (bp: Bp) => void, onDark: (dark: boolean) => void) {
    this.onBp = onBp;
    this.onDark = onDark;
  }

  start(): void {
    this.logThemeSource();

    this.darkL = mediaquery.matchMediaSync('(dark-mode: true)');
    this.onDark(this.darkL.matches);
    this.darkL.on('change', (r: mediaquery.MediaQueryResult) => {
      this.onDark(r.matches);
    });

    this.compactL = mediaquery.matchMediaSync('(width<600vp)');
    this.compactL.on('change', (r: mediaquery.MediaQueryResult) => {
      if (r.matches) {
        this.onBp('compact');
      }
    });
    this.mediumL = mediaquery.matchMediaSync('(600vp<=width<840vp)');
    this.mediumL.on('change', (r: mediaquery.MediaQueryResult) => {
      if (r.matches) {
        this.onBp('medium');
      }
    });
    this.wideL = mediaquery.matchMediaSync('(width>=840vp)');
    this.wideL.on('change', (r: mediaquery.MediaQueryResult) => {
      if (r.matches) {
        this.onBp('expanded');
      }
    });
    if (this.compactL.matches) {
      this.onBp('compact');
    } else if (this.mediumL.matches) {
      this.onBp('medium');
    } else {
      this.onBp('expanded');
    }
  }

  stop(): void {
    if (this.compactL !== undefined) {
      this.compactL.off('change');
    }
    if (this.mediumL !== undefined) {
      this.mediumL.off('change');
    }
    if (this.wideL !== undefined) {
      this.wideL.off('change');
    }
    if (this.darkL !== undefined) {
      this.darkL.off('change');
    }
  }

  private logThemeSource(): void {
    try {
      const cfg = getContext().resourceManager.getConfigurationSync();
      const a: string = String(cfg.colorMode);
      const b: string = String(getContext().config.colorMode);
      const c: string = String(mediaquery.matchMediaSync('(dark-mode: true)').matches);
      mark('colorMode rm=' + a + ' ctx=' + b + ' mq=' + c);
    } catch (e) {
      mark('colorMode read failed');
    }
  }
}

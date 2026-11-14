import web_webview from '@ohos.web.webview';
import { DURATION, spring } from '../model/Motion';
import { Palette, palette } from '../model/Palette';
import { Session } from '../model/Session';
import { SettingsSheet } from './SettingsSheet';

// 浮在面上的两件东西：设置面板，以及 AppGallery Connect 的登录页。两者都是覆盖层，
// 不参与翻面，所以单独成组件，页面只决定它们何时出现。
@Component
export struct Overlays {
  @Prop dark: boolean = true;
  @Prop showSettings: boolean = false;
  @Prop device: string = '';
  @Prop agcState: string = '';
  @Prop agcUser: string = '';
  @Prop agcAuthUrl: string = '';
  @Prop devices: string[] = [];
  @Prop link: number = 0;

  @Link leftOpen: boolean;

  session: Session = new Session();
  authController: web_webview.WebviewController = new web_webview.WebviewController();

  onOptions: () => void = () => {};
  onCloseSettings: () => void = () => {};
  onPickProject: () => void = () => {};
  onDevice: (value: string) => void = () => {};
  onAgcLogin: () => void = () => {};
  onAgcLogout: () => void = () => {};
  onDevices: (list: string[]) => void = () => {};
  onAgcCancel: () => void = () => {};

  private p(): Palette {
    return palette(this.dark);
  }

  build() {
    Column() {
      if (this.showSettings) {
        SettingsSheet({
          dark: this.dark,
          project: AppStorage.get<string>('ide.project') ?? '',
          device: this.device,
          linkState: AppStorage.get<string>('ide.link') ?? '',
          agcState: this.agcState,
          agcUser: this.agcUser,
          aboutInfo: AppStorage.get<string>('ide.aboutInfo') ?? '',
          busy: this.session.busy,
          onOptions: () => {
            this.onOptions();
          },
          onClose: () => {
            this.onCloseSettings();
          },
          onPickProject: () => {
            this.onPickProject();
          },
          onDevice: (value: string) => {
            this.onDevice(value);
          },
          devices: this.devices,
          link: this.link,
          onAgcLogin: () => {
            this.onAgcLogin();
          },
          onAgcLogout: () => {
            this.onAgcLogout();
          },
          onDevices: (list: string[]) => {
            this.onDevices(list);
          }
        })
      }

      if (this.agcAuthUrl.length > 0) {
        // The authorization page runs inside the app: the redirect it makes to loopback
        // carries the tempToken, and intercepting it here keeps the whole exchange in
        // the sandbox instead of relying on an external browser.
        Column() {
          Row({ space: 8 }) {
            Text('AppGallery Connect 登录')
              .fontSize(15)
              .fontColor(this.p().textPrimary)
              .layoutWeight(1)
            Text('取消')
              .fontSize(14)
              .fontColor(this.p().brand)
              .onClick(() => {
                this.onAgcCancel();
              })
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })

          Web({ src: this.agcAuthUrl, controller: this.authController })
            .width('100%')
            .layoutWeight(1)
            .javaScriptAccess(true)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.p().bg)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

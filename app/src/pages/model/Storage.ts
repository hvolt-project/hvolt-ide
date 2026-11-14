import { Session } from './Session';

/**
 * 页面需要自己镜像成 @State 的那几个值。其余一律只写 AppStorage，由订阅它的面板直接读，
 * 所以这份清单本身就是「哪些状态必须经过页面」的唯一出处。
 */
export class PublishedMirrors {
  devices: string[] = [];
  link: number = 0;
  linkText: string = '';
  statusText: string = '';
  log: string = '';
  hlog: string = '';
  device: string = '';
  agcState: string = '';
  agcUser: string = '';
  agcUrl: string = '';
  statusTone: number = 0;
}

/**
 * 唯一发布点：把 Session 当前的面板数据写进 AppStorage，并返回页面要镜像的那几个值。
 * 写在这里而不是页面里，是为了让键名只有一处定义，新增面板只改这一个文件。
 */
export function publishSession(s: Session): PublishedMirrors {
  AppStorage.setOrCreate('ide.files', s.files);
  AppStorage.setOrCreate('ide.tabs', s.openTabs);
  AppStorage.setOrCreate('ide.dirty', s.dirtyTabs);
  AppStorage.setOrCreate('ide.current', s.current);
  AppStorage.setOrCreate('ide.pos', s.curLine + ',' + s.curCol);
  AppStorage.setOrCreate('ide.chromeHidden', s.chromeHidden);
  AppStorage.setOrCreate('ide.projects', s.projects);
  AppStorage.setOrCreate('ide.project', s.project);
  AppStorage.setOrCreate('ide.device', s.device);
  AppStorage.setOrCreate('ide.status', s.statusText);
  AppStorage.setOrCreate('ide.tone', s.statusTone);
  AppStorage.setOrCreate('ide.log', s.log);
  AppStorage.setOrCreate('ide.hlog', s.hlog);
  AppStorage.setOrCreate('ide.link', s.linkState);
  AppStorage.setOrCreate('ide.outline', s.outline);
  AppStorage.setOrCreate('ide.outlineNote', s.outlineNote);
  AppStorage.setOrCreate('ide.agc', s.agc.state);
  AppStorage.setOrCreate('ide.busy', s.busy);
  AppStorage.setOrCreate('ide.projectInfo',
    s.project + ' · ' + s.sourceCount + ' 个源文件\n' + s.projectPath());
  AppStorage.setOrCreate('ide.signingInfo',
    (s.signingReady ? '调试签名材料已就位' : '未找到签名材料') + '\n' + s.agc.state);
  AppStorage.setOrCreate('ide.aboutInfo', s.version);

  const m = new PublishedMirrors();
  m.devices = s.devices;
  m.link = s.link;
  m.linkText = s.linkState;
  m.statusText = s.statusText;
  m.log = s.log;
  m.hlog = s.hlog;
  m.device = s.device;
  m.agcState = s.agc.state;
  m.agcUser = s.agc.user;
  m.agcUrl = s.agc.url;
  m.statusTone = s.statusTone;
  return m;
}

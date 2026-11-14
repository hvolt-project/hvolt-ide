// 设备侧的落盘实现：把 SessionLog 需要的三个动作接到 @ohos.file.fs。
//
// 单独成文件是为了让 Log.ts 保持可在 Node 上加载：@ohos 的导入一旦出现在 Log.ts 顶部，
// 纯逻辑测试就整份加载失败。

import fs from '@ohos.file.fs';
import type { LogStorage } from './Log.ts';

export class FsStorage implements LogStorage {
  exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  read(path: string): string {
    return fs.readTextSync(path);
  }

  append(path: string, line: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
    try {
      fs.writeSync(file.fd, line);
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
  }
}

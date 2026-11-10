import taskpool from '@ohos.taskpool';
import hilog from '@ohos.hilog';
import { hvoltCall, streamNext } from 'libnavi.so';

// The toolchain call blocks until the device answers, and the device asks the user to
// trust a newly generated key before it answers. That wait on the UI thread reads as a
// hang to the system, so the call runs in a worker and the sheet survives the prompt.
// One worker entry for every toolchain command: build takes tens of seconds and a device
// push can take longer, and both are synchronous NAPI calls that block whatever thread
// runs them. The system kills a blocked UI thread after six seconds.
@Concurrent
export function hvoltInWorker(argvJson: string, cwd: string, filesDir: string): string {
  return hvoltCall(argvJson, cwd, filesDir);
}

export function hvoltAsync(argv: string[], cwd: string, filesDir: string,
  done: (raw: string) => void): void {
  taskpool.execute(hvoltInWorker, JSON.stringify(argv), cwd, filesDir)
    .then((raw: Object) => {
      // The whole envelope, in chunks: a panic inside the toolchain leaves its message at the
      // end of `output`, and hilog cuts a line at a fixed length, so a 200-character prefix
      // shows the steps that succeeded and hides the one that failed.
      const text: string = raw as string;
      const CHUNK: number = 800;
      for (let at = 0; at < text.length; at += CHUNK) {
        hilog.info(0x0000, 'hvoltide', 'RAW %{public}s %{public}s',
          argv.length > 0 ? argv[0] : '', text.substring(at, at + CHUNK));
      }
      done(text);
    })
    .catch((e: Error) => {
      done('{"code":-1,"output":"' + e.message + '"}');
    });
}

// Blocks in this worker until the device writes a line or the wait expires. The caller
// re-issues it on every answer, so the stream is paced by the device, not by a timer.
@Concurrent
export function streamNextInWorker(handle: number, from: number, max: number, waitMs: number): string {
  return streamNext(handle, from, max, waitMs);
}

export function streamNextAsync(handle: number, from: number, max: number, waitMs: number,
  done: (raw: string) => void): void {
  taskpool.execute(streamNextInWorker, handle, from, max, waitMs)
    .then((raw: Object) => {
      done(raw as string);
    })
    .catch((e: Error) => {
      done('{"next":' + from + ',"rows":[]}');
    });
}

@Concurrent
export function connectInWorker(addr: string, filesDir: string): string {
  hilog.info(0x0000, 'hvoltide', 'worker connect start %{public}s', addr);
  const raw = hvoltCall(JSON.stringify(['device', 'connect', addr]), filesDir, filesDir);
  hilog.info(0x0000, 'hvoltide', 'worker connect end');
  return raw;
}

export function connectAsync(addr: string, filesDir: string, done: (raw: string) => void): void {
  taskpool.execute(connectInWorker, addr, filesDir)
    .then((raw: Object) => {
      hilog.info(0x0000, 'hvoltide', 'connect result %{public}s', (raw as string).substring(0, 400));
      done(raw as string);
    })
    .catch((e: Error) => {
      done('{"code":-1,"output":"' + e.message + '"}');
    });
}

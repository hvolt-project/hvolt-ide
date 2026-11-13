import taskpool from '@ohos.taskpool';
import hilog from '@ohos.hilog';
import { hvoltCall, streamNext, streamStart } from 'libnavi.so';

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
      // taskpool 层失败（含 libnavi panic）：进程已经结束，不是「还在跑」。写 -1 会让
      // job_output 永远报 running。这里必须收口成失败，消息留在 output 里。
      done('{"code":1,"output":"' + e.message + '"}');
    });
}

// Opening the stream talks to the device before it answers, so it blocks exactly like the toolchain
// calls do. Run on the UI thread it froze the page for the length of the device's handshake, and
// the system kills a blocked UI thread after six seconds.
@Concurrent
export function streamStartInWorker(paramsJson: string, filesDir: string): string {
  return streamStart(paramsJson, filesDir);
}

export function streamStartAsync(paramsJson: string, filesDir: string,
  done: (raw: string) => void): void {
  taskpool.execute(streamStartInWorker, paramsJson, filesDir)
    .then((raw: Object) => {
      done(raw as string);
    })
    .catch((e: Error) => {
      // taskpool 层失败（含 libnavi panic）：进程已经结束，不是「还在跑」。写 -1 会让
      // job_output 永远报 running。这里必须收口成失败，消息留在 output 里。
      done('{"code":1,"output":"' + e.message + '"}');
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

// A device that never answers would otherwise hold a worker for as long as the page lives, and
// enough of those starve the ArkTS VM of worker threads — which is what leaves the WebView unable
// to start. Five seconds is the handshake budget: past it the answer is "no answer", reported.
const CONNECT_TIMEOUT_MS: number = 5000;

export function connectAsync(addr: string, filesDir: string, done: (raw: string) => void): void {
  const task = new taskpool.Task(connectInWorker, addr, filesDir);
  let settled = false;
  const timer: number = setTimeout(() => {
    if (settled) {
      return;
    }
    settled = true;
    taskpool.cancel(task).catch(() => {
    });
    hilog.warn(0x0000, 'hvoltide', 'connect timeout after %{public}d ms', CONNECT_TIMEOUT_MS);
    done('{"code":-1,"output":"连接超时 ' + CONNECT_TIMEOUT_MS + 'ms 无应答"}');
  }, CONNECT_TIMEOUT_MS);

  taskpool.execute(task)
    .then((raw: Object) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      hilog.info(0x0000, 'hvoltide', 'connect result %{public}s', (raw as string).substring(0, 400));
      done(raw as string);
    })
    .catch((e: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      done('{"code":-1,"output":"' + e.message + '"}');
    });
}

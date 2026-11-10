// Speech input through the device's own recognizer.
//
// The engine takes PCM frames and returns text as it recognises them, so the microphone button
// can write straight into the draft instead of producing a file to upload. Both halves are
// wrapped here because neither is usable alone: a recognizer without audio never fires, and
// audio without the recognizer is a file nobody asked for.

import { speechRecognizer } from '@kit.CoreSpeechKit';
import audio from '@ohos.multimedia.audio';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import hilog from '@ohos.hilog';

const SAMPLE_RATE: number = 16000;
const CHUNK_BYTES: number = 2560;

export type AsrText = (text: string, final: boolean) => void;
export type AsrError = (message: string) => void;

export class AsrSession {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private sessionId: string = '';
  private running: boolean = false;
  /** Guards the await above `running`, which is only set after the engine answers. */
  private starting: boolean = false;
  private onText: AsrText = () => {
  };
  private onError: AsrError = () => {
  };

  active(): boolean {
    return this.running;
  }

  /** Starts a recognition session; text arrives through `onText` as it is recognised. */
  async start(onText: AsrText, onError: AsrError): Promise<void> {
    if (this.running || this.starting) {
      return;
    }
    this.starting = true;
    const granted = await this.ensureMicPermission();
    if (!granted) {
      this.starting = false;
      this.onError('没有麦克风权限');
      return;
    }
    this.onText = onText;
    this.onError = onError;
    this.sessionId = 'sess-' + Date.now();
    this.running = true;

    try {
      this.engine = await speechRecognizer.createEngine({
        language: 'zh-CN',
        online: 1
      });
    } catch (e) {
      this.running = false;
      this.starting = false;
      this.onError('语音引擎不可用：' + (e as Error).message);
      return;
    }
    this.starting = false;

    this.engine.setListener({
      onStart: (sessionId: string, eventMessage: string) => {
        hilog.info(0x0000, 'hvoltide', 'asr start %{public}s', sessionId);
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        const text = result.result;
        if (text !== undefined && text.length > 0) {
          this.onText(text, result.isFinal === true);
        }
      },
      onComplete: (sessionId: string, eventMessage: string) => {
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        this.onError('识别失败：' + errorMessage);
      }
    });

    try {
      // The recognizer rejects a session without an explicit audio description: it needs
      // sampleBit 16 spelled out, not inferred from the capturer.
      this.engine.startListening({
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: SAMPLE_RATE,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      await this.startCapture();
    } catch (e) {
      this.stop();
      this.onError('录音启动失败：' + (e as Error).message);
    }
  }

  /** Creating a capturer without the runtime grant fails as "Capturer Create failed". */
  private async ensureMicPermission(): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(getContext(),
        ['ohos.permission.MICROPHONE']);
      for (const code of result.authResults) {
        if (code === 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  private async startCapture(): Promise<void> {
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      }
    };
    this.capturer = await audio.createAudioCapturer(options);
    this.capturer.on('readData', (buffer: ArrayBuffer) => {
      if (!this.running || this.engine === null) {
        return;
      }
      try {
        this.engine.writeAudio(this.sessionId, new Uint8Array(buffer));
      } catch (e) {
      }
    });
    await this.capturer.start();
  }

  /** Ends the session and releases both the microphone and the engine. */
  stop(): void {
    this.running = false;
    const capturer = this.capturer;
    this.capturer = null;
    if (capturer !== null) {
      capturer.stop().catch(() => {
      });
      capturer.release().catch(() => {
      });
    }
    const engine = this.engine;
    this.engine = null;
    if (engine !== null) {
      try {
        engine.finish(this.sessionId);
      } catch (e) {
      }
      try {
        engine.shutdown();
      } catch (e) {
      }
    }
  }
}

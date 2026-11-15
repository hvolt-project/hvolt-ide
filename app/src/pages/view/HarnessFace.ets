import { TURN_VISIBLE } from '../model/Motion';
import { Session } from '../model/Session';
import { AskQuestion } from '../model/Ask';
import { ChatLine, ChatPanel } from './ChatPanel';
import { makeLine } from '../model/Lines';
import { clearTodos } from '../harness/tools/Todo';

// harness 面：chat 面板加上它这一侧的翻转姿态。数据来自 Session，动作转成回调交给页面，
// 只有对话内容与忙碌标记用 @Link 双向绑回页面状态。
@Component
export struct HarnessFace {
  @Prop dark: boolean = true;
  @Prop keyboardInset: number = 0;
  @Prop statTurns: number = 0;
  @Prop statSteps: number = 0;
  @Prop statTokens: number = 0;
  @Prop statCache: number = -1;
  @Prop statPressure: number = 0;
  /** 工作步骤展示档位，透传给 chat 面。 */
  @Prop viewMode: string = 'compact';
  @Prop collapseTiming: string = 'immediate';
  @Prop statContext: number = 0;
  @Prop statRate: number = 0;
  @Prop model: string = '';
  @Prop provider: string = '';
  @Prop askQuestions: AskQuestion[] = [];
  @Prop askIndex: number = 0;
  // 这一面的姿态：角度与本轮是否正在翻转，由页面统一持有。
  @Prop flipAngle: number = 0;
  @Prop flipBusy: boolean = false;

  @Link lines: ChatLine[];
  @Link busy: boolean;

  session: Session = new Session();

  onSend: (text: string, images: string[]) => void = () => {};
  onClose: () => void = () => {};

  private append(line: ChatLine): void {
    const lines: ChatLine[] = this.lines.slice();
    lines.push(line);
    this.lines = lines;
  }

  build() {
    ChatPanel({
      dark: this.dark,
      keyboardInset: this.keyboardInset,
      statVisible: this.keyboardInset <= 0,
      statTurns: this.statTurns,
      statSteps: this.statSteps,
      statTokens: this.statTokens,
      statCache: this.statCache,
      statPressure: this.statPressure,
      viewMode: this.viewMode,
      collapseTiming: this.collapseTiming,
      statContext: this.statContext,
      statRate: this.statRate,
      project: this.session.project,
      provider: this.provider,
      model: this.model,
      files: this.session.files,
      askAnswers: this.session.askAnswers,
      lines: $lines,
      busy: $busy,
      // Bound to the session, so a question raised by a tool appears without extra plumbing.
      askQuestions: this.askQuestions,
      askIndex: this.askIndex,
      actions: {
        send: (text: string, images: string[]) => {
          this.onSend(text, images);
        },
        stop: () => {
          this.session.chatStop();
        },
        reset: () => {
          this.session.chatReset();
          // 计划属于这一段对话：对话清了它还挂着，顶上就是一份不存在的进度。
          // 放在清 lines 之前，让随后的 onLinesChanged 读到的是空表。
          clearTodos();
          this.lines = [];
        },
        answerAsk: (selected: string[], custom: string) => {
          this.session.answerCurrent(selected, custom);
        },
        cancelAsk: () => {
          this.session.cancelAsk();
        },
        listSkills: () => {
          this.session.loadSkill('').then((text: string) => {
            for (const line of text.split('\n')) {
              this.append(makeLine('tool', line, 'skill'));
            }
          });
        },
        compact: async () => {
          const attempt = await this.session.chatCompact();
          // 压缩只改模型看到的历史，对话本身照原样留着；结果作为一行工具记录追加。
          // 四种没压成的原因分别说明，一律写「无需压缩」会把失败说成没事可做。
          let text: string = '无需压缩';
          if (attempt.outcome !== null) {
            text = '已压缩 seq ' + attempt.outcome.from + '-' + attempt.outcome.to + '（约 ' +
              attempt.outcome.tokens + ' tokens）';
          } else if (attempt.stop === 'busy') {
            text = '现在有回合在跑，压缩要等它结束';
          } else if (attempt.stop === 'no-region') {
            text = '没有可安全压缩的区间（历史太短，或切点会拆开工具调用）';
          } else if (attempt.stop === 'empty-summary') {
            text = '摘要为空，历史未改动';
          } else if (attempt.stop === 'not-smaller') {
            text = '压缩后没有变小，历史未改动';
          }
          this.append(makeLine('tool', text, 'compact'));
        },
        close: () => {
          this.onClose();
        }
      }
    })
      .shadow({ radius: 22, color: '#00000099', offsetX: 0, offsetY: 0 })
      // 翻面：harness 面始终比 IDE 面多 180°，两面夹角恒定，跟手时不会出现角度跳变。
      .rotate({ y: 1, angle: this.flipAngle + 180, perspective: 800 })
      // 与 IDE 面同一条规则：只有朝前的一面可见。harness 面在 180° 一侧，所以它露面
      // 的区间与 IDE 面相反。
      .visibility(Math.abs(this.flipAngle) > TURN_VISIBLE ? Visibility.Visible : Visibility.Hidden)
      // 同一条规则：只在翻转期间合并绘制。
      .renderGroup(this.flipBusy)
  }
}

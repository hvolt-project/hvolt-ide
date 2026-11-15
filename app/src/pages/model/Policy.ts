// 对话面的「工作步骤展示」档位。
//
// 照 DSH 的 TranscriptViewMode 与 ChatPresentationPolicy：档位本身不写渲染代码，只声明渲染层要读
// 的能力（stepGrouping / settledReasoningPreview / collapseTiming），渲染层按能力裁剪，日志与事件
// 始终写全量。这张表与 dsh-client-ui-chat/lib/client.js:12665-12689 的四段一致。
//
// DSH 原表还有 foldCompletedTurns / liveProcessDetail / mode 三个字段，本工程渲染层从不读它们：
// 前两个的能力已由 stepGrouping 表达（已完成 turn 一律进组），故删掉而不是留着让人以为改它有用。
// 若将来要兑现「组标题里显示正在跑的完整命令」（liveProcessDetail 的真实语义），再加回来。

export type TranscriptViewMode = 'compact' | 'standard' | 'detailed' | 'verbose';

export type StepGrouping = 'collapsed' | 'history' | 'none';

/** 折叠时机：与档位正交——完成就折，还是等下一条输入才折（DSH collapseTiming）。 */
export type CollapseTiming = 'immediate' | 'next-input';

export const COLLAPSE_TIMINGS: CollapseTiming[] = ['immediate', 'next-input'];

export function collapseTimingLabel(timing: CollapseTiming): string {
  return timing === 'next-input' ? '下一条输入时' : '立即';
}

export function collapseTimingOf(text: string): CollapseTiming {
  return text === 'next-input' ? 'next-input' : 'immediate';
}

export interface ChatPresentationPolicy {
  /** 已完成 turn 的过程行折成组头、只有历史 turn 折、还是一律不折。 */
  stepGrouping: StepGrouping;
  /** 静止的推理行是否在「思考」标题旁预览首行。 */
  settledReasoningPreview: boolean;
  /**
   * 正在跑的这一轮，组头是否带当前细节（正在执行的命令/参数）。DSH 的 liveProcessDetail：
   * 精简与全部关，标准与详细开。关掉时组头只有活动短语。
   */
  liveProcessDetail: boolean;
  /**
   * 正在跑的这一轮是否也折成一行（点开才看过程）。只有精简档打开：
   * 「精简」的含义就是先占一行，想看过程自己去点；标准/详细保持 DSH 的边跑边开。
   */
  foldWhileRunning: boolean;
  /** 已完成的 turn 什么时候折：立即，还是等下一条输入。 */
  collapseTiming: CollapseTiming;
}

export const TRANSCRIPT_VIEW_MODES: TranscriptViewMode[] = ['compact', 'standard', 'detailed', 'verbose'];

/** 面板上的名字。取值与 DSH 一致，中文只做人读的标签。 */
export function viewModeLabel(mode: TranscriptViewMode): string {
  if (mode === 'compact') {
    return '精简';
  }
  if (mode === 'standard') {
    return '标准';
  }
  if (mode === 'detailed') {
    return '详细';
  }
  return '全部';
}

export function viewModeOf(text: string): TranscriptViewMode {
  if (text === 'standard' || text === 'detailed' || text === 'verbose') {
    return text;
  }
  return 'compact';
}

export const DEFAULT_TRANSCRIPT_VIEW: TranscriptViewMode = 'compact';

export function presentationPolicyFor(mode: TranscriptViewMode): ChatPresentationPolicy {
  if (mode === 'standard') {
    return {
      stepGrouping: 'collapsed',
      settledReasoningPreview: true,
      liveProcessDetail: true,
      foldWhileRunning: false,
      collapseTiming: 'immediate'
    };
  }
  if (mode === 'detailed') {
    return {
      stepGrouping: 'history',
      settledReasoningPreview: true,
      liveProcessDetail: true,
      foldWhileRunning: false,
      collapseTiming: 'immediate'
    };
  }
  if (mode === 'verbose') {
    return {
      stepGrouping: 'none',
      settledReasoningPreview: true,
      liveProcessDetail: false,
      foldWhileRunning: false,
      collapseTiming: 'immediate'
    };
  }
  // 精简：折叠同标准，但组头不带实时细节、静止推理也不预览；跑着的这一轮同样折起来。
  return {
    stepGrouping: 'collapsed',
    settledReasoningPreview: false,
    liveProcessDetail: false,
    foldWhileRunning: true,
    collapseTiming: 'immediate'
  };
}

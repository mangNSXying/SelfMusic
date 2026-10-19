import { InsightIntentExecutor, insightIntent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Log } from '@ohos/flutter_ohos';
import AvSessionBridge from '../media/AvSessionBridge';

const TAG = 'SelfMusicInsight';

/**
 * PlayMusicList 意图执行器（播控中心「冷启动续播 / 历史歌单」入口）。
 *
 * 播控中心对已销毁应用展示「最近播放」信息（AVMetadata.avQueueId/avQueueName/
 * avQueueImage 上报的歌单），点击后经 Intents Kit 调用本意图回拉应用：
 * - 冷启动：本执行器先于 Dart main() 完成触发（生命周期 onCreate →
 *   onWindowStageCreate → onExecuteInUIAbilityForegroundMode），此时经
 *   AvSessionBridge.handleInsightPlay 暂存请求，Dart 就绪（boot 通道 ready）
 *   后统一放行投递；
 * - 热启动：直接投递 Dart（insightPlay 命令 → PlayerProvider 恢复/续播链）。
 *
 * 参数格式由系统入口（播控中心）下发，播放语义为「续播该歌单/最近队列」：
 * playlistId 提取采用候选键防御式探测（本地无 PlayMusicList 入参 Schema
 * 权威文档），取不到即降级为续播语义（null）。
 *
 * 注意：不调用 windowStage.loadContent——FlutterAbility 已在
 * onWindowStageCreate 装载 Flutter 页面，二次装载会顶掉应用界面。
 */
export default class PlayMusicListExecutor extends InsightIntentExecutor {
  async onExecuteInUIAbilityForegroundMode(name: string, param: Record<string, Object>,
    windowStage: window.WindowStage): Promise<insightIntent.ExecuteResult> {
    Log.i(TAG, `前台模式意图调用：${name}`);
    const result: insightIntent.ExecuteResult = {
      code: 0
    };
    if (name !== 'PlayMusicList') {
      Log.w(TAG, `不支持的意图：${name}`);
      result.code = 404;
      return result;
    }
    AvSessionBridge.handleInsightPlay(PlayMusicListExecutor.extractPlaylistId(param));
    return result;
  }

  async onExecuteInUIAbilityBackgroundMode(name: string,
    param: Record<string, Object>): Promise<insightIntent.ExecuteResult> {
    Log.i(TAG, `后台模式意图调用：${name}`);
    const result: insightIntent.ExecuteResult = {
      code: 0
    };
    if (name !== 'PlayMusicList') {
      Log.w(TAG, `不支持的意图：${name}`);
      result.code = 404;
      return result;
    }
    AvSessionBridge.handleInsightPlay(PlayMusicListExecutor.extractPlaylistId(param));
    return result;
  }

  /** 候选键探测歌单标识：string 直取，number 转字符串，缺失/空降级 null。 */
  private static extractPlaylistId(param: Record<string, Object>): string | null {
    const probe = (key: string): string | null => {
      const v: Object | undefined = param[key];
      if (typeof v === 'string' && v.length > 0) {
        return v;
      }
      if (typeof v === 'number' && !Number.isNaN(v)) {
        return `${v}`;
      }
      return null;
    };
    return probe('playlistId') ?? probe('queueId') ?? probe('entityId');
  }
}

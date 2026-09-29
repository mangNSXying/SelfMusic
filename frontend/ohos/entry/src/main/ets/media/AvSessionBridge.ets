
import {
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'SelfMusicAVSession';
/** 与 Dart 侧（ohos_media_session.dart）约定的媒体播控通道。 */
const AV_CHANNEL = 'selfmusic/avsession';
/** 点通知/播控卡拉回应用（与启动命令一致）。 */
const BUNDLE_NAME = 'com.shamiko.selfmusic';
const ABILITY_NAME = 'EntryAbility';

/**
 * AVSession 媒体播控桥（2026-09-29 定稿设计）：
 *
 * 职责：把 Dart 侧的播放状态镜像到系统 AVSession，使通知栏/锁屏/播控中心
 * 出现媒体播控卡（收藏/上一首/播放暂停/下一首/循环模式），并在播放期间
 * 申请 AUDIO_PLAYBACK 长时任务兜底进程保活。
 *
 * 通道协议（selfmusic/avsession）：
 * - Dart → ArkTS：
 *   - start：首次播放时创建会话。参数=元数据+播放态全集（见 buildMetadata/
 *     buildPlaybackState）；幂等——会话已存在时降级为 updateMetadata+updateState。
 *   - updateMetadata：切歌时推元数据（assetId/title/artist/album/duration/
 *     coverPath/lyric）。
 *   - updateState：播放/暂停/进度/收藏/循环模式变化时推播放态。
 *   - destroy：主动收卡（销毁会话+停长时任务）。
 * - ArkTS → Dart（系统播控卡按钮 → 方法名直传）：
 *   play / pause / stop / playNext / playPrevious / seek(time) /
 *   setLoopMode(mode) / toggleFavorite(assetId)。
 *
 * 会话生命周期（AVSession 规范）：create → setAVMetadata + setAVPlaybackState
 * + on(命令) → activate；元数据与命令注册必须先于 activate。
 * 长时任务：activate 成功后申请；API 20+ 接入 AVSession 后通知由 AVSession
 * 统一接管，不会与长时任务通知重复。
 * 进度：系统按 position{elapsedTime, updateTime} 自算，仅在状态变化时推送。
 * 歌词：标准 LRC 文本经 AVMetadata.lyric 下发（上限 40960 字节由 Dart 侧
 * 按 UTF-8 截断保证，ArkTS 侧信任传入）。
 */
export default class AvSessionBridge implements MethodCallHandler {
  private context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;
  private session: avSession.AVSession | null = null;
  private backgroundRunning: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** EntryAbility.configureFlutterEngine 中调用。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.channel = new MethodChannel(messenger, AV_CHANNEL);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, 'AVSession 桥就绪');
  }

  /** EntryAbility.onDestroy / Dart destroy 后的资源回收。 */
  shutdown(): void {
    if (this.backgroundRunning) {
      this.backgroundRunning = false;
      backgroundTaskManager.stopBackgroundRunning(this.context)
        .then((): void => {
          Log.i(TAG, '长时任务已停止');
        })
        .catch((err: BusinessError): void => {
          Log.w(TAG, `停止长时任务失败：${err.code} ${err.message}`);
        });
    }
    if (this.session) {
      const session = this.session;
      this.session = null;
      session.destroy()
        .then((): void => {
          Log.i(TAG, 'AVSession 已销毁，播控卡收起');
        })
        .catch((err: BusinessError): void => {
          Log.w(TAG, `销毁 AVSession 失败：${err.code} ${err.message}`);
        });
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'start':
        this.handleStart(call, result);
        break;
      case 'updateMetadata':
        this.handleUpdateMetadata(call, result);
        break;
      case 'updateState':
        this.handleUpdateState(call, result);
        break;
      case 'destroy':
        this.shutdown();
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private handleStart(call: MethodCall, result: MethodResult): void {
    if (this.session) {
      // 幂等：会话已存在时等价于全量刷新。
      this.handleUpdateMetadata(call, result);
      return;
    }
    avSession.createAVSession(this.context, 'SelfMusic', 'audio')
      .then(async (session: avSession.AVSession): Promise<void> => {
        this.session = session;
        this.registerCommands(session);
        await session.setAVMetadata(this.buildMetadata(call));
        await session.setAVPlaybackState(this.buildPlaybackState(call));
        await session.activate();
        await this.startBackgroundTask();
        Log.i(TAG, `AVSession 已激活（assetId=${AvSessionBridge.argString(call, 'assetId') ?? ''}）`);
        result.success(null);
      })
      .catch((err: BusinessError): void => {
        Log.e(TAG, `启动 AVSession 失败：${err.code} ${err.message}`);
        this.shutdown();
        result.error(`${err.code}`, err.message, null);
      });
  }

  private handleUpdateMetadata(call: MethodCall, result: MethodResult): void {
    const session = this.session;
    if (!session) {
      // 竞态保护：会话未建（或已销毁）时静默丢弃。
      result.success(null);
      return;
    }
    session.setAVMetadata(this.buildMetadata(call))
      .then((): void => {
        result.success(null);
      })
      .catch((err: BusinessError): void => {
        Log.w(TAG, `更新元数据失败：${err.code} ${err.message}`);
        result.error(`${err.code}`, err.message, null);
      });
  }

  private handleUpdateState(call: MethodCall, result: MethodResult): void {
    const session = this.session;
    if (!session) {
      result.success(null);
      return;
    }
    session.setAVPlaybackState(this.buildPlaybackState(call))
      .then((): void => {
        result.success(null);
      })
      .catch((err: BusinessError): void => {
        Log.w(TAG, `更新播放态失败：${err.code} ${err.message}`);
        result.error(`${err.code}`, err.message, null);
      });
  }

  /**
   * 系统播控卡按钮 → Dart。方法名直传，Dart 侧统一在
   * ohos_media_session.dart 注册回调并转发给播放器。
   */
  private registerCommands(session: avSession.AVSession): void {
    session.on('play', (): void => {
      this.channel?.invokeMethod('play', null);
    });
    session.on('pause', (): void => {
      this.channel?.invokeMethod('pause', null);
    });
    session.on('stop', (): void => {
      this.channel?.invokeMethod('stop', null);
    });
    session.on('playNext', (): void => {
      this.channel?.invokeMethod('playNext', null);
    });
    session.on('playPrevious', (): void => {
      this.channel?.invokeMethod('playPrevious', null);
    });
    session.on('seek', (time: number): void => {
      this.channel?.invokeMethod('seek', time);
    });
    session.on('setLoopMode', (mode: avSession.LoopMode): void => {
      this.channel?.invokeMethod('setLoopMode', Number(mode));
    });
    session.on('toggleFavorite', (assetId: string): void => {
      this.channel?.invokeMethod('toggleFavorite', assetId);
    });
  }

  /** 取参 helper：argument 返回 Any，显式转换避免 arkts-no-any-unknown。 */
  private static argString(call: MethodCall, key: string): string | null {
    return call.argument(key) as string | null;
  }

  private static argNumber(call: MethodCall, key: string): number | null {
    return call.argument(key) as number | null;
  }

  private static argBool(call: MethodCall, key: string): boolean | null {
    return call.argument(key) as boolean | null;
  }

  private buildMetadata(call: MethodCall): avSession.AVMetadata {
    const assetId = AvSessionBridge.argString(call, 'assetId');
    const metadata: avSession.AVMetadata = {
      assetId: assetId != null ? assetId : ''
    };
    const title = AvSessionBridge.argString(call, 'title');
    if (title != null) {
      metadata.title = title;
    }
    const artist = AvSessionBridge.argString(call, 'artist');
    if (artist != null) {
      metadata.artist = artist;
    }
    const album = AvSessionBridge.argString(call, 'album');
    if (album != null) {
      metadata.album = album;
    }
    const duration = AvSessionBridge.argNumber(call, 'duration');
    if (duration != null) {
      metadata.duration = duration;
    }
    const lyric = AvSessionBridge.argString(call, 'lyric');
    if (lyric != null) {
      metadata.lyric = lyric;
    }
    // 封面（coverPath）暂不下发：实测三种格式（PixelMap / 裸路径 / file://
    // string）均触发服务端封面校验异常（PixelMap → GetMediaImageTopic 失败，
    // string → isImageValid 判非法 → 通知更新失败 980000502），待卡片机制
    // 跑通后单攻封面格式。缺省时播控卡显示应用图标。
    return metadata;
  }

  private buildPlaybackState(call: MethodCall): avSession.AVPlaybackState {
    const state: avSession.AVPlaybackState = {};
    const playbackState = AvSessionBridge.argNumber(call, 'state');
    if (playbackState != null) {
      state.state = this.mapPlaybackState(playbackState);
    }
    const position = AvSessionBridge.argNumber(call, 'position');
    if (position != null) {
      const positionValue: avSession.PlaybackPosition = {
        elapsedTime: position,
        updateTime: Date.now()
      };
      state.position = positionValue;
    }
    const speed = AvSessionBridge.argNumber(call, 'speed');
    if (speed != null) {
      state.speed = speed;
    }
    const isFavorite = AvSessionBridge.argBool(call, 'isFavorite');
    if (isFavorite != null) {
      state.isFavorite = isFavorite;
    }
    const loopMode = AvSessionBridge.argNumber(call, 'loopMode');
    if (loopMode != null) {
      state.loopMode = this.mapLoopMode(loopMode);
    }
    return state;
  }

  /** Dart 侧统一用 int 传递枚举，此处显式映射（含非法值兜底）。 */
  private mapPlaybackState(state: number): avSession.PlaybackState {
    switch (state) {
      case 2:
        return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
      case 3:
        return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
      case 6:
        return avSession.PlaybackState.PLAYBACK_STATE_STOP;
      case 7:
        return avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
      case 11:
        return avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
      default:
        return avSession.PlaybackState.PLAYBACK_STATE_INITIAL;
    }
  }

  /**
   * PlayMode → LoopMode 映射（int 约定，与 Dart 侧 ohos_media_session.dart 一致）：
   * 0=sequence→SEQUENCE，1=loopOne→SINGLE，2=loopList→LIST，3=weighted→SHUFFLE。
   */
  private mapLoopMode(mode: number): avSession.LoopMode {
    switch (mode) {
      case 0:
        return avSession.LoopMode.LOOP_MODE_SEQUENCE;
      case 1:
        return avSession.LoopMode.LOOP_MODE_SINGLE;
      case 2:
        return avSession.LoopMode.LOOP_MODE_LIST;
      case 3:
        return avSession.LoopMode.LOOP_MODE_SHUFFLE;
      default:
        return avSession.LoopMode.LOOP_MODE_SEQUENCE;
    }
  }

  /**
   * AUDIO_PLAYBACK 长时任务（进程保活兜底）。失败仅记录不阻断——AVSession
   * 本身已接管通知与播控（且实测 fvp 音频路径切后台本就不停）。
   */
  private async startBackgroundTask(): Promise<void> {
    const wantItem: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: ABILITY_NAME
    };
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [wantItem],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const wantAgentObj = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        this.context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wantAgentObj);
      this.backgroundRunning = true;
      Log.i(TAG, 'AUDIO_PLAYBACK 长时任务已申请');
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `申请长时任务失败（不影响播控卡）：${e.code} ${e.message}`);
    }
  }
}

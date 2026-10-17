
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
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

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
 *     buildPlaybackState）+ showControls（false=播控卡隐藏模式：不建会话，
 *     仅申请长时任务保活）；幂等——会话已存在时降级为 updateMetadata+updateState。
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
 * 封面（两段式，2026-09-30 定稿）：元数据先行（卡片秒出，缺封面显示应用
 * 图标），封面异步解码后经第二次 setAVMetadata 补推。coverPath 为本应用
 * 沙箱绝对路径，走 fd→ImageSource→PixelMap 进 IPC 共享内存——string uri
 * 形式要求 av_session 服务进程能访问该路径，沙箱路径它读不了（实测
 * isImageValid 判非法，980000502 阻断整卡）；PixelMap 保持引用至替换完成
 * 才 release（过早释放疑似首轮 GetMediaImageTopic checkFail 死因）。
 */
export default class AvSessionBridge implements MethodCallHandler {
  private context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;
  private session: avSession.AVSession | null = null;
  private backgroundRunning: boolean = false;
  /** 当前已生效封面（保持引用防送显失败，替换完成后才 release）。 */
  private currentCover: image.PixelMap | null = null;
  /** 上次封面路径（去重：同曲重复 updateMetadata 不重解码）。 */
  private lastCoverPath: string | null = null;
  /** 封面任务票据（快速切歌竞态：仅最新任务可生效）。 */
  private coverJob: number = 0;

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
    this.lastCoverPath = null;
    this.coverJob++;
    this.releaseCover();
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
    // 播控卡隐藏模式（Dart 侧 showControls=false，设置开关关）：不建 AVSession
    // （通知栏/锁屏/播控中心无卡片），仅申请 AUDIO_PLAYBACK 长时任务保活——
    // 后台播放与按钮开关解耦（与 Android 前台服务恒注册同一语义）。
    if (AvSessionBridge.argBool(call, 'showControls') === false) {
      this.startBackgroundTask()
        .then((): void => {
          Log.i(TAG, '播控卡隐藏模式：仅长时任务保活');
          result.success(null);
        })
        .catch((): void => {
          // startBackgroundTask 内部已记录失败不阻断，此处仅为满足 Promise 必须处理。
        });
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
        this.updateCover(call).catch((): void => {
          // updateCover 内部全量兜底，此处仅为满足 Promise 必须处理。
        });
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
        this.updateCover(call).catch((): void => {
          // updateCover 内部全量兜底，此处仅为满足 Promise 必须处理。
        });
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
    // 封面不走本方法（两段式，见 updateCover）：先推文字卡片，封面异步补。
    return metadata;
  }

  /**
   * 封面异步补推（两段式第二段）。同曲去重；快速切歌用票据竞态淘汰过期
   * 解码；任何失败仅记日志——封面不应当有能力影响卡片与播放。
   *
   * 问题2修复：无图/解码失败必须显式清系统侧封面（二次 setAVMetadata），
   * 仅靠“省略 mediaImage”系统会保留上一首；且空分支必须递增 coverJob，
   * 否则上一首在飞的解码完成后会把旧图盖到新曲上。
   */
  private async updateCover(call: MethodCall): Promise<void> {
    const path = AvSessionBridge.argString(call, 'coverPath');
    const session = this.session;
    if (!session) {
      return;
    }
    if (path == null || path === '') {
      // 无封面曲目：作废在飞解码、释放本地引用，并显式下发无图元数据清系统侧。
      this.coverJob++;
      this.lastCoverPath = null;
      this.releaseCover();
      try {
        const metadata = this.buildMetadata(call);
        (metadata as ESObject).mediaImage = null;
        await session.setAVMetadata(metadata);
        Log.i(TAG, '无封面已清图');
      } catch (err) {
        const e = err as BusinessError;
        Log.w(TAG, `清图失败（忽略）：${e.code} ${e.message}`);
      }
      return;
    }
    if (path === this.lastCoverPath && this.currentCover != null) {
      return;
    }
    const job = ++this.coverJob;
    try {
      const pixelMap = await this.decodeCover(path);
      if (job !== this.coverJob || this.session !== session) {
        pixelMap.release().catch((): void => {
        });
        return;
      }
      const metadata = this.buildMetadata(call);
      metadata.mediaImage = pixelMap;
      await session.setAVMetadata(metadata);
      // 新封面已过 IPC：释放上一张、接住新引用（保持引用直至下次替换）。
      this.releaseCover();
      this.currentCover = pixelMap;
      this.lastCoverPath = path;
      Log.i(TAG, '封面已补推');
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `封面补推失败（忽略）：${e.code} ${e.message}`);
      // 解码失败同样清图，避免残留上一首（如下一首封面文件损坏/半图残留）。
      this.lastCoverPath = null;
      this.releaseCover();
      try {
        const fallback = this.buildMetadata(call);
        (fallback as ESObject).mediaImage = null;
        const cur = this.session;
        if (job === this.coverJob && cur === session) {
          await cur.setAVMetadata(fallback);
        }
      } catch (clearErr) {
        const ce = clearErr as BusinessError;
        Log.w(TAG, `失败清图失败（忽略）：${ce.code} ${ce.message}`);
      }
    }
  }

  /**
   * 沙箱封面文件 → PixelMap：fd → ImageSource → 解码。PixelMap 送显序列化
   * 上限 128MB=宽*高*每像素字节（FAQ faqs-avsession-26，超限系统自动压缩，
   * 但直接拒收更稳）；封面为内嵌专辑图通常 <1500px，48MB 防线仅御异常大图
   * （DecodingOptions.sampleSize 实际仅支持 1，故解码后用 scale 等比缩）。
   */
  private async decodeCover(path: string): Promise<image.PixelMap> {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const source = image.createImageSource(file.fd);
      try {
        const pixelMap = await source.createPixelMap();
        const info = await pixelMap.getImageInfo();
        const w = info.size.width;
        const h = info.size.height;
        const bytes = w * h * 4;
        const maxBytes = 48 * 1024 * 1024;
        if (bytes > maxBytes) {
          const factor = Math.sqrt(maxBytes / bytes);
          await pixelMap.scale(factor, factor);
          Log.i(TAG, `封面超大已等比缩放：${w}x${h} → x${factor.toFixed(2)}`);
        }
        Log.i(TAG, `封面解码：${w}x${h} ${path}`);
        return pixelMap;
      } finally {
        await source.release();
      }
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 释放上一张封面（IPC 完成后释放己方引用，共享内存系统侧自持）。 */
  private releaseCover(): void {
    const cover = this.currentCover;
    this.currentCover = null;
    if (cover != null) {
      cover.release().catch((err: BusinessError): void => {
        Log.w(TAG, `旧封面释放失败（忽略）：${err.code} ${err.message}`);
      });
    }
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
   * 本身已接管通知与播控（且实测 AVPlayer 音频路径切后台本就不停）。
   */
  private async startBackgroundTask(): Promise<void> {
    if (this.backgroundRunning) {
      return;
    }
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

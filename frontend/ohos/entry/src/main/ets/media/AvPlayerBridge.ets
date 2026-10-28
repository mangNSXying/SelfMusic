
import {
  Any,
  EventChannel,
  EventSink,
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler
} from '@ohos/flutter_ohos';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'SelfMusicAvPlayer';
/** 与 Dart 侧（just_audio_avplayer.dart）约定的方法通道。 */
const METHOD_CHANNEL = 'selfmusic/avplayer';
/** 与 Dart 侧约定的事件通道（100ms 位置上报等）。 */
const EVENT_CHANNEL = 'selfmusic/avplayer/events';

/**
 * 单个 AVPlayer 实例的桥内状态。
 *
 * load 的完成信号来自 stateChange（prepared / error），因此把 resolve/reject
 * 暂存在 entry 上。just_audio 不保证同一实例的 load 串行；用 loadSeq 让迟到
 * 的旧装载立即作废，避免旧曲在新曲之后重新占回播放器。
 */
class PlayerEntry {
  readonly id: string;
  player: media.AVPlayer | null = null;
  /** 本地文件 fd（-1=无）；由本桥负责关闭（AVFileDescriptor 文档口径）。 */
  fd: number = -1;
  /**
   * 装载代次：每来一次 load 自增。旧装载（含 reset/prepare 的 await）在恢复
   * 执行前必须核对代次，否则迟到的旧装载会把新曲音源重新置回旧曲。
   * just_audio 的 setAudioSource 并不会串行化同一实例的 platform.load。
   */
  loadSeq: number = 0;
  /** 本次 load 已置源，等待 initialized 后触发 prepare。 */
  preparing: boolean = false;
  onPrepared: ((durationMs: number) => void) | null = null;
  onLoadError: ((message: string) => void) | null = null;
  /** error 事件与 error 状态可能先后到达，只上报一次。 */
  errorReported: boolean = false;
  /** error 态 reset 不可靠，下次 load 直接 release + 重建。 */
  needsRecreate: boolean = false;
  released: boolean = false;
  /** prepared 前收到的音量（AVPlayer 仅在 prepared 后允许 setVolume）。 */
  pendingVolume: number = -1;
  /** prepared 前收到的 play（just_audio 激活平台时会先 play 再 load）。 */
  pendingPlay: boolean = false;

  constructor(id: string) {
    this.id = id;
  }
}

/**
 * 鸿蒙系统 AVPlayer 播放桥（just_audio 的 ohos 播放后端）。
 *
 * 通道协议：
 * - 方法 selfmusic/avplayer：
 *   createPlayer{playerId} / load{playerId,url|filePath,headersJson,initialPositionMs}
 *   play / pause / stop / seek{positionMs} / setVolume{volume} /
 *   reset / dispose / disposeAll（后三者均带 playerId 或空）
 * - 事件 selfmusic/avplayer/events：Map 负载，均带 type + playerId：
 *   state / position / duration / buffered / seekDone / ended / error /
 *   audioInterrupt（hint/forced/wasPlaying/positionMs）
 *
 * 关键约定：
 * - 监听必须先于置源注册（官方要求，否则丢 stateChange）；
 * - 文件走 fdSrc（fd 由桥持有到 reset/dispose 再关）；
 * - 带请求头走 createMediaSourceWithUrl + setMediaSource（API 12+）；
 * - play 在 prepared 之前到达时挂起，prepared 后补发；pause/stop/reset/装载
 *   失败会取消挂起，避免“先点播放再点暂停”在装载完成后又自己响起来；
 * - error 态只上报并标记重建，不在错误回调里 reset（错误回调内 reset 可能再次抛错）。
 */
export default class AvPlayerBridge implements MethodCallHandler, StreamHandler {
  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private sink: EventSink | null = null;
  private players: Map<string, PlayerEntry> = new Map();

  /** EntryAbility.configureFlutterEngine 中调用：注册方法/事件双通道。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.methodChannel = new MethodChannel(messenger, METHOD_CHANNEL);
    this.methodChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(messenger, EVENT_CHANNEL);
    this.eventChannel.setStreamHandler(this);
    Log.w(TAG, 'AVPlayer 桥就绪');
  }

  /** EntryAbility.onDestroy 中调用：释放所有播放器。 */
  shutdown(): void {
    const entries: PlayerEntry[] = [];
    this.players.forEach((entry: PlayerEntry): void => {
      entries.push(entry);
    });
    this.players.clear();
    for (let i = 0; i < entries.length; i++) {
      entries[i].pendingPlay = false;
      this.releaseEntry(entries[i]);
    }
    this.sink = null;
  }

  onListen(args: Any, events: EventSink): void {
    this.sink = events;
    Log.i(TAG, '事件通道已订阅');
  }

  onCancel(args: Any): void {
    this.sink = null;
    Log.i(TAG, '事件通道已取消');
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.dispatch(call, result).catch((e: Error): void => {
      Log.e(TAG, `${call.method} 异常: ${e.message}`);
      result.error('avplayer', e.message, null);
    });
  }

  private async dispatch(call: MethodCall, result: MethodResult): Promise<void> {
    switch (call.method) {
      case 'createPlayer':
        await this.handleCreate(call, result);
        return;
      case 'load':
        await this.handleLoad(call, result);
        return;
      case 'play':
        await this.handlePlay(call, result);
        return;
      case 'pause':
        await this.handlePause(call, result);
        return;
      case 'stop':
        await this.handleStop(call, result);
        return;
      case 'seek':
        this.handleSeek(call, result);
        return;
      case 'setVolume':
        this.handleSetVolume(call, result);
        return;
      case 'reset':
        await this.handleReset(call, result);
        return;
      case 'dispose':
        await this.handleDispose(call, result, false);
        return;
      case 'disposeAll':
        await this.handleDispose(call, result, true);
        return;
      default:
        result.notImplemented();
        return;
    }
  }

  // ---------- 方法实现 ----------

  private async handleCreate(call: MethodCall, result: MethodResult): Promise<void> {
    const id = this.stringArg(call, 'playerId');
    if (id === null) {
      result.error('400', '缺少 playerId', null);
      return;
    }
    // 先同步摘表再异步释放：释放（AVPlayer.release）期间晚到的 dispose 按 id
    // 找不到旧实例，不会把随后新建的同 id 播放器误删。真机 2026-10-28：原生
    // 错误触发 just_audio 自动降级 dispose，与回退重建交错，新实例被迟到
    // 的 delete 清掉，之后所有 load/play/setVolume 全是 404 播放器不存在。
    const old = this.detachEntry(id);
    if (old !== undefined) {
      await this.releaseEntry(old);
    }
    const entry = new PlayerEntry(id);
    await this.createNative(entry);
    this.players.set(id, entry);
    result.success(null);
  }

  private async handleLoad(call: MethodCall, result: MethodResult): Promise<void> {
    const id = this.stringArg(call, 'playerId');
    if (id === null) {
      result.error('400', '缺少 playerId', null);
      return;
    }
    const entry = this.players.get(id);
    if (entry === undefined) {
      result.error('404', `播放器不存在: ${id}`, null);
      return;
    }
    const url = this.stringArg(call, 'url');
    const filePath = this.stringArg(call, 'filePath');
    if (url === null && filePath === null) {
      result.error('400', 'url/filePath 至少一个', null);
      return;
    }
    const headers = this.parseHeaders(this.stringArg(call, 'headersJson'));
    const initialMs = this.numberArg(call, 'initialPositionMs') ?? 0;
    const seq = this.beginLoad(entry);
    Log.w(TAG, `load ${id} seq=${seq} file=${filePath !== null} headerCount=${Object.keys(headers).length} initialMs=${initialMs}`);
    try {
      const durationMs = await this.loadInternal(entry, seq, url, filePath, headers, initialMs);
      this.ensureCurrentLoad(entry, seq);
      Log.w(TAG, `load ${id} ok durationMs=${durationMs}`);
      const out: Map<string, string | number> = new Map();
      out.set('durationMs', durationMs);
      result.success(out);
    } catch (e) {
      const msg = (e as Error).message;
      Log.e(TAG, `load 失败 ${id} seq=${seq}: ${msg}`);
      result.error('load', msg, null);
    }
  }

  private async handlePlay(call: MethodCall, result: MethodResult): Promise<void> {
    const entry = this.entryOf(call);
    const player = entry !== null ? entry.player : null;
    if (entry === null || player === null) {
      result.error('404', '播放器不存在', null);
      return;
    }
    const state = player.state;
    if (state === 'playing') {
      result.success(null);
      return;
    }
    if (state !== 'prepared' && state !== 'paused' && state !== 'completed') {
      if (state === 'idle' || state === 'initialized' || state === 'stopped') {
        // just_audio 激活平台时会先下发 play、再 load：此刻原生还没有可播
        // 音源，不能丢意图。load 完成（prepared + 初始 seek）后补发一次。
        entry.pendingPlay = true;
        Log.w(TAG, `play 挂起：state=${state}，prepared 后补发`);
      } else {
        entry.pendingPlay = false;
        Log.w(TAG, `play 忽略：state=${state}`);
      }
      result.success(null);
      return;
    }
    try {
      await player.play();
      result.success(null);
    } catch (e) {
      Log.w(TAG, `play 忽略异常 ${entry.id}: ${(e as BusinessError).code}`);
      result.success(null);
    }
  }

  private async handlePause(call: MethodCall, result: MethodResult): Promise<void> {
    const entry = this.entryOf(call);
    const player = entry !== null ? entry.player : null;
    if (entry === null || player === null) {
      result.error('404', '播放器不存在', null);
      return;
    }
    const hadPendingPlay = entry.pendingPlay;
    entry.pendingPlay = false;
    if (player.state !== 'playing') {
      if (hadPendingPlay) {
        Log.w(TAG, `pause 取消挂起的 play：state=${player.state}`);
      }
      result.success(null);
      return;
    }
    try {
      await player.pause();
      result.success(null);
    } catch (e) {
      Log.w(TAG, `pause 忽略异常 ${entry.id}: ${(e as BusinessError).code}`);
      result.success(null);
    }
  }

  private async handleStop(call: MethodCall, result: MethodResult): Promise<void> {
    const entry = this.entryOf(call);
    const player = entry !== null ? entry.player : null;
    if (entry === null || player === null) {
      result.error('404', '播放器不存在', null);
      return;
    }
    entry.pendingPlay = false;
    const state = player.state;
    if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') {
      result.success(null);
      return;
    }
    try {
      await player.stop();
      result.success(null);
    } catch (e) {
      Log.w(TAG, `stop 忽略异常 ${entry.id}: ${(e as BusinessError).code}`);
      result.success(null);
    }
  }

  private handleSeek(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    const player = entry !== null ? entry.player : null;
    const ms = this.numberArg(call, 'positionMs');
    if (entry === null || player === null) {
      result.error('404', '播放器不存在', null);
      return;
    }
    if (ms === null || ms < 0) {
      result.error('400', 'positionMs 非法', null);
      return;
    }
    const state = player.state;
    if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') {
      Log.w(TAG, `seek 忽略：state=${state}`);
      result.success(null);
      return;
    }
    try {
      player.seek(ms, media.SeekMode.SEEK_CLOSEST);
      result.success(null);
    } catch (e) {
      result.error(`${(e as BusinessError).code}`, (e as BusinessError).message, null);
    }
  }

  private handleSetVolume(call: MethodCall, result: MethodResult): void {
    const entry = this.entryOf(call);
    const player = entry !== null ? entry.player : null;
    const volume = this.numberArg(call, 'volume');
    if (entry === null || player === null) {
      result.error('404', '播放器不存在', null);
      return;
    }
    if (volume === null) {
      result.error('400', 'volume 非法', null);
      return;
    }
    const v = volume < 0 ? 0 : (volume > 1 ? 1 : volume);
    const state = player.state;
    if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') {
      // 装载期 just_audio 会先下发音量：暂存，prepared 后补发
      // （AVPlayer 在 idle/initialized 调 setVolume 会报 5400102）。
      entry.pendingVolume = v;
      result.success(null);
      return;
    }
    try {
      player.setVolume(v);
      result.success(null);
    } catch (e) {
      Log.w(TAG, `setVolume 忽略异常 ${entry.id}: ${(e as BusinessError).code}`);
      result.success(null);
    }
  }

  private async handleReset(call: MethodCall, result: MethodResult): Promise<void> {
    const entry = this.entryOf(call);
    if (entry === null || entry.player === null) {
      result.success(null);
      return;
    }
    await this.resetEntry(entry);
    result.success(null);
  }

  private async handleDispose(call: MethodCall, result: MethodResult, all: boolean): Promise<void> {
    if (all) {
      const entries: PlayerEntry[] = [];
      this.players.forEach((entry: PlayerEntry): void => {
        entries.push(entry);
      });
      this.players.clear();
      for (let i = 0; i < entries.length; i++) {
        entries[i].pendingPlay = false;
        await this.releaseEntry(entries[i]);
      }
      result.success(null);
      return;
    }
    const id = this.stringArg(call, 'playerId');
    if (id === null) {
      result.error('400', '缺少 playerId', null);
      return;
    }
    // 同步摘表后再 await 释放：与 handleCreate 同一竞态防线（见该处注释）。
    const entry = this.detachEntry(id);
    if (entry !== undefined) {
      entry.pendingPlay = false;
      await this.releaseEntry(entry);
    }
    result.success(null);
  }

  /**
   * 同步摘除 id 对应实例：其后按 id 到达的消息（play/seek/setVolume/load）
   * 立即按“不存在”处理，释放过程不再影响同名新实例。
   */
  private detachEntry(id: string): PlayerEntry | undefined {
    const entry = this.players.get(id);
    this.players.delete(id);
    return entry;
  }

  // ---------- 原生实现 ----------

  private async createNative(entry: PlayerEntry): Promise<void> {
    const player = await media.createAVPlayer();
    entry.player = player;
    entry.released = false;
    this.attachListeners(entry);
  }

  private attachListeners(entry: PlayerEntry): void {
    const player = entry.player;
    if (player === null) {
      return;
    }
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
      this.onStateChange(entry, state, reason);
    });
    player.on('error', (err: BusinessError): void => {
      this.onError(entry, err);
    });
    player.on('timeUpdate', (time: number): void => {
      this.emitEvent(entry.id, 'position', time);
    });
    player.on('durationUpdate', (duration: number): void => {
      this.emitEvent(entry.id, 'duration', duration);
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number): void => {
      this.emitBuffered(entry.id, infoType, value);
    });
    player.on('seekDone', (time: number): void => {
      this.emitEvent(entry.id, 'seekDone', time);
    });
    player.on('endOfStream', (): void => {
      this.emitEvent(entry.id, 'ended', 0);
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      this.onAudioInterrupt(entry, event);
    });
  }

  private onStateChange(entry: PlayerEntry, state: media.AVPlayerState, reason: media.StateChangeReason): void {
    Log.w(TAG, `${entry.id} state=${state} reason=${reason}`);
    if (state === 'initialized') {
      if (entry.preparing) {
        const player = entry.player;
        if (player !== null) {
          const seq = entry.loadSeq;
          player.prepare().catch((e: BusinessError): void => {
            this.failLoad(entry, `prepare 失败 ${e.code}: ${e.message}`, seq);
          });
        }
      }
      return;
    }
    if (state === 'prepared') {
      const duration = entry.player !== null ? entry.player.duration : -1;
      const resolve = entry.onPrepared;
      entry.onPrepared = null;
      entry.onLoadError = null;
      entry.preparing = false;
      this.emitStateEvent(entry.id, 'prepared');
      if (entry.pendingVolume >= 0 && entry.player !== null) {
        try {
          entry.player.setVolume(entry.pendingVolume);
        } catch (e) {
          Log.w(TAG, `${entry.id} 补发音量失败: ${(e as BusinessError).code}`);
        }
        entry.pendingVolume = -1;
      }
      if (resolve !== null) {
        resolve(duration);
      }
      return;
    }
    if (state === 'playing') {
      this.emitStateEvent(entry.id, 'playing');
      return;
    }
    if (state === 'paused') {
      // 手动暂停时 just_audio 已先翻 playing=false 并冻结在墙钟插值位置；
      // 这里把原生真实停顿位置一并带回，适配层在 _emit 前刷新 _position，
      // 避免进度条回跳到上一次 timeUpdate（最多 100ms）。
      this.emitStateEvent(entry.id, 'paused', this.readCurrentTime(entry.player));
      return;
    }
    if (state === 'completed') {
      this.emitStateEvent(entry.id, 'completed');
      return;
    }
    if (state === 'stopped') {
      this.emitStateEvent(entry.id, 'stopped');
      return;
    }
    if (state === 'idle') {
      this.emitStateEvent(entry.id, 'idle');
      return;
    }
    if (state === 'error') {
      if (!entry.errorReported) {
        entry.errorReported = true;
        entry.needsRecreate = true;
        this.emitError(entry.id, -1, 'AVPlayer 进入 error 状态');
      }
      this.failLoad(entry, 'AVPlayer 进入 error 状态', entry.loadSeq);
      return;
    }
    // released 不上报（dispose 路径无需驱动 Dart 状态机）。
  }

  /**
   * 音频焦点中断（系统强制暂停/恢复）。
   *
   * 关键：鸿蒙系统抢占焦点时会直接暂停音频流，但 AVPlayer.state 仍保持
   * 'playing'，且不会自动恢复。这里必须：
   * - 在 pause/stop hint 时主动 player.pause()，让 stateChange 驱动 Dart 同步；
   * - 把中断时刻的 currentTime 一并上报，Dart 侧据此把进度从墙钟插值回退到
   *   真实停顿点；
   * - RESUME 只通知 Dart，由 PlayerProvider 按 audio_focus_enabled 决定是否
   *   play()，避免“忽略音频焦点”开关失效。
   */
  private onAudioInterrupt(entry: PlayerEntry, event: audio.InterruptEvent): void {
    const player = entry.player;
    if (player === null || entry.released) {
      return;
    }
    const wasPlaying = player.state === 'playing';
    const forced = event.forceType === audio.InterruptForceType.INTERRUPT_FORCE;
    let positionMs = -1;
    try {
      positionMs = player.currentTime;
    } catch (e) {
      // 极端状态下 currentTime 不可读：位置交给 Dart 侧最后一次上报。
      positionMs = -1;
    }
    Log.w(TAG, `${entry.id} audioInterrupt hint=${event.hintType} force=${event.forceType} wasPlaying=${wasPlaying} pos=${positionMs}`);

    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
      this.emitInterrupt(entry.id, 'pause', forced, wasPlaying, positionMs);
      if (wasPlaying) {
        player.pause().catch((e: BusinessError): void => {
          Log.w(TAG, `${entry.id} 焦点暂停同步失败: ${e.code}`);
        });
      }
      return;
    }
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      this.emitInterrupt(entry.id, 'stop', forced, wasPlaying, positionMs);
      if (wasPlaying) {
        // 用 pause 而非 stop：保留当前进度，用户可手动继续。
        player.pause().catch((e: BusinessError): void => {
          Log.w(TAG, `${entry.id} 焦点停止同步失败: ${e.code}`);
        });
      }
      return;
    }
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      this.emitInterrupt(entry.id, 'resume', forced, wasPlaying, positionMs);
      return;
    }
    // DUCK/UNDUCK 由系统调音量，播放状态不变；只记录日志。
  }

  private onError(entry: PlayerEntry, err: BusinessError): void {
    Log.e(TAG, `${entry.id} error ${err.code}: ${err.message}`);
    // 5400102 = Operate Not Permit（如装载期 setVolume / 非法状态操作）。
    // 不是源/网络错误，不能打断装载或触发重建。
    if (err.code === 5400102) {
      return;
    }
    if (!entry.errorReported) {
      entry.errorReported = true;
      entry.needsRecreate = true;
      this.emitError(entry.id, err.code, err.message);
    }
    this.failLoad(entry, `AVPlayer 错误 ${err.code}: ${err.message}`, entry.loadSeq);
  }

  /**
   * 开始一次新装载：自增代次并让上一次仍在等待的装载立即失败。
   * 旧装载之后的 `result.error` 由 Dart 侧按切歌令牌静默丢弃；这里若继续
   * 共用 onPrepared/onLoadError，旧装载的 15s 超时还会误伤新装载。
   */
  private beginLoad(entry: PlayerEntry): number {
    const seq = ++entry.loadSeq;
    const reject = entry.onLoadError;
    entry.onPrepared = null;
    entry.onLoadError = null;
    entry.preparing = false;
    entry.pendingPlay = false;
    if (reject !== null) {
      reject('装载已被新请求取代');
    }
    return seq;
  }

  /** 旧装载在任意 await 之后恢复执行前核对：不是最新代次立即退出。 */
  private ensureCurrentLoad(entry: PlayerEntry, seq: number): void {
    if (entry.loadSeq !== seq) {
      throw new Error('装载已被新请求取代');
    }
  }

  private failLoad(entry: PlayerEntry, message: string, seq: number): void {
    if (entry.loadSeq !== seq) {
      return;
    }
    const reject = entry.onLoadError;
    entry.onLoadError = null;
    entry.onPrepared = null;
    entry.preparing = false;
    entry.pendingPlay = false;
    if (reject !== null) {
      reject(message);
    }
  }

  private async loadInternal(entry: PlayerEntry, seq: number, url: string | null, filePath: string | null,
    headers: Record<string, string>, initialMs: number): Promise<number> {
    this.ensureCurrentLoad(entry, seq);
    if (entry.player === null || entry.needsRecreate || entry.released) {
      if (entry.player !== null) {
        await this.releaseEntry(entry);
      }
      await this.createNative(entry);
      this.ensureCurrentLoad(entry, seq);
    }
    const player = entry.player;
    if (player === null) {
      throw new Error('AVPlayer 创建失败');
    }
    // 上一个源先复位：just_audio 可能对同一实例连续 load。
    if (player.state !== 'idle') {
      try {
        await player.reset();
        this.ensureCurrentLoad(entry, seq);
      } catch (e) {
        if (entry.loadSeq !== seq) {
          throw new Error('装载已被新请求取代');
        }
        Log.w(TAG, `${entry.id} reset 失败，重建播放器: ${(e as BusinessError).code}`);
        await this.releaseEntry(entry);
        await this.createNative(entry);
        this.ensureCurrentLoad(entry, seq);
      }
    }
    const active = entry.player;
    if (active === null) {
      throw new Error('AVPlayer 重建失败');
    }
    this.ensureCurrentLoad(entry, seq);
    Log.w(TAG, `loadInternal ${entry.id} seq=${seq} state=${active.state} file=${filePath !== null} headerCount=${Object.keys(headers).length}`);
    this.closeFd(entry);
    entry.errorReported = false;
    entry.needsRecreate = false;
    entry.preparing = true;

    const prepared = new Promise<number>((resolve: (durationMs: number) => void,
      reject: (message: string) => void): void => {
      if (entry.loadSeq !== seq) {
        reject('装载已被新请求取代');
        return;
      }
      entry.onPrepared = resolve;
      entry.onLoadError = reject;
    });

    try {
      if (filePath !== null) {
        const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
        entry.fd = file.fd;
        const stat = fs.statSync(filePath);
        active.fdSrc = {
          fd: file.fd,
          offset: 0,
          length: stat.size
        };
        Log.w(TAG, `load ${entry.id} fdSrc fd=${file.fd} size=${stat.size}`);
      } else if (url !== null && Object.keys(headers).length > 0) {
        const source = media.createMediaSourceWithUrl(url, headers);
        Log.w(TAG, `load ${entry.id} setMediaSource headerCount=${Object.keys(headers).length}`);
        // 注意：部分系统版本 setMediaSource 同步返回 void（非 Promise），
        // 不能 .then；进度由 stateChange（initialized→prepared）与 15s
        // 兜底定时器驱动，失败由 error 回调收口。
        try {
          active.setMediaSource(source);
        } catch (e) {
          this.failLoad(entry, `setMediaSource 失败 ${(e as BusinessError).code}: ${(e as BusinessError).message}`, seq);
          throw new Error('setMediaSource 失败');
        }
      } else if (url !== null) {
        active.url = url;
        Log.w(TAG, `load ${entry.id} url set state=${active.state}`);
      } else {
        throw new Error('url/filePath 均为空');
      }
    } catch (e) {
      throw new Error(`置源失败: ${(e as BusinessError).message}`);
    }

    const timer = setTimeout((): void => {
      this.failLoad(entry, 'load 超时（15s 未 prepared）', seq);
    }, 15000);
    try {
      const duration = await prepared;
      this.ensureCurrentLoad(entry, seq);
      if (initialMs > 0) {
        try {
          active.seek(initialMs, media.SeekMode.SEEK_CLOSEST);
        } catch (e) {
          Log.w(TAG, `${entry.id} 初始 seek 失败: ${(e as BusinessError).code}`);
        }
      }
      // just_audio 激活平台时可能先 play 再 load：在 prepared + 初始 seek
      // 都完成后再补发，避免从 0 起播闪一下再跳到断点。
      const pendingPlayer = entry.player;
      if (entry.pendingPlay && pendingPlayer !== null && !entry.released) {
        entry.pendingPlay = false;
        Log.w(TAG, `${entry.id} load 完成，补发挂起的 play`);
        pendingPlayer.play().catch((e: BusinessError): void => {
          Log.w(TAG, `${entry.id} 补发 play 失败: ${e.code}`);
        });
      }
      return duration;
    } finally {
      clearTimeout(timer);
    }
  }

  private async resetEntry(entry: PlayerEntry): Promise<void> {
    const player = entry.player;
    this.closeFd(entry);
    entry.preparing = false;
    entry.onPrepared = null;
    entry.onLoadError = null;
    entry.pendingPlay = false;
    if (player === null) {
      return;
    }
    try {
      if (player.state !== 'idle' && player.state !== 'released') {
        await player.reset();
      }
      entry.errorReported = false;
      entry.needsRecreate = false;
    } catch (e) {
      Log.w(TAG, `${entry.id} reset 失败，标记重建: ${(e as BusinessError).code}`);
      entry.needsRecreate = true;
    }
  }

  private async releaseEntry(entry: PlayerEntry): Promise<void> {
    this.closeFd(entry);
    const player = entry.player;
    entry.player = null;
    entry.released = true;
    entry.preparing = false;
    entry.onPrepared = null;
    if (entry.onLoadError !== null) {
      const reject = entry.onLoadError;
      entry.onLoadError = null;
      reject('播放器已释放');
    }
    if (player === null) {
      return;
    }
    try {
      player.off('stateChange');
      player.off('error');
      player.off('timeUpdate');
      player.off('durationUpdate');
      player.off('bufferingUpdate');
      player.off('seekDone');
      player.off('endOfStream');
      player.off('audioInterrupt');
      await player.release();
    } catch (e) {
      Log.w(TAG, `${entry.id} release 失败: ${(e as BusinessError).code}`);
    }
  }

  private closeFd(entry: PlayerEntry): void {
    if (entry.fd < 0) {
      return;
    }
    try {
      fs.closeSync(entry.fd);
    } catch (e) {
      Log.w(TAG, `${entry.id} 关闭 fd 失败: ${(e as BusinessError).code}`);
    }
    entry.fd = -1;
  }

  // ---------- 事件 ----------

  private emitEvent(playerId: string, type: string, value: number): void {
    const event: Map<string, string | number> = new Map();
    event.set('type', type);
    event.set('playerId', playerId);
    event.set('value', value);
    this.sink?.success(event);
  }

  private emitStateEvent(playerId: string, state: string, positionMs: number = -1): void {
    const event: Map<string, string | number> = new Map();
    event.set('type', 'state');
    event.set('playerId', playerId);
    event.set('state', state);
    if (positionMs >= 0) {
      event.set('positionMs', positionMs);
    }
    this.sink?.success(event);
  }

  /** 读原生当前播放位置（ms）；不可读时返回 -1，由 Dart 沿用最后一次上报。 */
  private readCurrentTime(player: media.AVPlayer | null): number {
    if (player === null) {
      return -1;
    }
    try {
      return player.currentTime;
    } catch (e) {
      return -1;
    }
  }

  private emitInterrupt(playerId: string, hint: string, forced: boolean,
    wasPlaying: boolean, positionMs: number): void {
    const event: Map<string, string | number> = new Map();
    event.set('type', 'audioInterrupt');
    event.set('playerId', playerId);
    event.set('hint', hint);
    event.set('forced', forced ? 1 : 0);
    event.set('wasPlaying', wasPlaying ? 1 : 0);
    event.set('positionMs', positionMs);
    this.sink?.success(event);
  }

  private emitBuffered(playerId: string, infoType: media.BufferingInfoType, value: number): void {
    const event: Map<string, string | number> = new Map();
    event.set('type', 'buffered');
    event.set('playerId', playerId);
    event.set('infoType', infoType);
    event.set('value', value);
    this.sink?.success(event);
  }

  private emitError(playerId: string, code: number, message: string): void {
    const event: Map<string, string | number> = new Map();
    event.set('type', 'error');
    event.set('playerId', playerId);
    event.set('code', code);
    event.set('message', message);
    this.sink?.success(event);
  }

  // ---------- 参数工具 ----------

  private stringArg(call: MethodCall, key: string): string | null {
    const v = call.argument(key) as string | null;
    return v ?? null;
  }

  private numberArg(call: MethodCall, key: string): number | null {
    const v = call.argument(key) as number | null;
    return v ?? null;
  }

  private parseHeaders(json: string | null): Record<string, string> {
    const out: Record<string, string> = {};
    if (json === null || json.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(json) as Record<string, string>;
      const keys: string[] = Object.keys(parsed);
      for (const k of keys) {
        out[k] = parsed[k];
      }
    } catch (e) {
      Log.w(TAG, `headersJson 解析失败: ${(e as Error).message}`);
    }
    return out;
  }

  private entryOf(call: MethodCall): PlayerEntry | null {
    const id = this.stringArg(call, 'playerId');
    if (id === null) {
      return null;
    }
    const entry = this.players.get(id);
    return entry !== undefined ? entry : null;
  }
}

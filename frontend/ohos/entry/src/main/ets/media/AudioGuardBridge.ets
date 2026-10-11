
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
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'SelfMusicAudioGuard';
/** 与 Dart 侧（playback_guard.dart）约定的方法通道（复用 Android 同名通道）。 */
const METHOD_CHANNEL = 'com.shamiko.selfmusic/audio_guard';
/** 与 Dart 侧（playback_guard.dart）约定的事件通道（Dart 订阅时注册原生监听）。 */
const EVENT_CHANNEL = 'com.shamiko.selfmusic/audio_guard/events';
/**
 * 首选输出设备查询用的渲染信息（音乐流）。content 字段自 API 10 起废弃，省略；
 * usage+rendererFlags 足以匹配系统侧的输出路由决策。
 */
const RENDERER_INFO: audio.AudioRendererInfo = {
  usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
  rendererFlags: 0
};

/**
 * 静音暂停 / 断连暂停的鸿蒙原生信号源（对照 Android 端 AudioGuard.kt）。
 *
 * 职责：向 Dart 侧（playback_guard.dart）上报两类音频环境事件——
 * - volume：媒体音量档位变化（Dart 侧判定归零→暂停）；
 * - outputLost：当前活跃输出设备断开（拔耳机/关蓝牙音箱→暂停）。
 *
 * 通道协议（与 Android 完全一致，Dart 解码逻辑零分叉）：
 * - 方法通道 com.shamiko.selfmusic/audio_guard：
 *   - getMediaVolume：返回当前媒体音量档位（number）；读取失败返回 null，
 *     Dart 侧按「未知」忽略。用于恢复前台时补判静音暂停。
 * - 事件通道 com.shamiko.selfmusic/audio_guard/events：
 *   - {type: 'volume', value: number}（仅 MEDIA 流，已按档位去重）；
 *   - {type: 'outputLost'}。
 *   Dart 订阅（onListen）时注册原生监听并回推当前音量；取消订阅
 *   （onCancel）时注销全部原生监听。
 *
 * 断连判定（三路信号协同，含到达顺序竞态处理）：
 * - activeOutput：活跃输出设备缓存（判定「断开的设备是不是正在用的那个」）；
 * - deviceChange(DISCONNECT)：设备离线事实源。仅当离线设备与 activeOutput
 *   为同一设备时上报 outputLost；
 * - preferOutputDeviceChangeForRendererInfo：系统首选输出切换事件。若旧
 *   activeOutput 仍在线，视为用户主动切换（蓝牙耳机→音箱），仅跟进缓存不
 *   上报；若已离线，视为断连后的自动回退，保留旧缓存等 deviceChange 判定
 *   （避免回退事件先到导致缓存被提前覆盖、漏报 outputLost）。
 *
 * API 兼容性：on('volumeChange')/getVolumeSync/getPreferredOutputDeviceForRendererInfoSync
 * 自 API 20 起标记废弃，但其替代 API（streamVolumeChange/getVolumeByStream）
 * 均为 since-20，超出本工程 compatibleSdkVersion（API 17），故沿用旧 API——
 * 在 API 17~26 全区间可用，仅存量废弃告警。
 */
export default class AudioGuardBridge implements MethodCallHandler, StreamHandler {
  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  /** Dart 侧事件接收端（订阅期间非空，取消订阅/销毁后置空）。 */
  private sink: EventSink | null = null;
  /** 上次上报的媒体音量档位（去重，-1 表示尚未上报）。 */
  private lastVolume: number = -1;
  /** 活跃输出设备缓存（断连判定的比对基准；null=查询失败/无输出设备）。 */
  private activeOutput: audio.AudioDeviceDescriptor | null = null;

  /** 媒体音量变化回调（类属性箭头函数：绑定 this 且引用稳定，off 注销需同一引用）。 */
  private onVolumeChange = (event: audio.VolumeEvent): void => {
    if (event.volumeType !== audio.AudioVolumeType.MEDIA) {
      return;
    }
    if (event.volume === this.lastVolume) {
      return;
    }
    this.emitVolume(event.volume);
  };

  /** 输出设备连接状态变化回调：断开活跃输出设备→outputLost；随后同步缓存。 */
  private onDeviceChange = (action: audio.DeviceChangeAction): void => {
    if (action.type === audio.DeviceChangeType.DISCONNECT) {
      for (const d of action.deviceDescriptors) {
        if (d.deviceRole === audio.DeviceRole.OUTPUT_DEVICE && this.sameDevice(d, this.activeOutput)) {
          Log.i(TAG, '活跃输出设备断开，上报 outputLost');
          this.emitOutputLost();
          break;
        }
      }
    }
    // 无论连接还是断开，处理后都刷新缓存（新连接的设备可能成为新的活跃输出）。
    this.refreshActiveOutput();
  };

  /**
   * 首选输出设备变化回调：旧设备仍在线=用户主动切换→跟进缓存；
   * 已离线=断连自动回退→保留旧缓存，等 deviceChange(DISCONNECT) 判定。
   */
  private onPreferredChange = (devices: audio.AudioDeviceDescriptors): void => {
    if (this.activeOutput === null || this.isDeviceOnline(this.activeOutput)) {
      this.activeOutput = devices.length > 0 ? devices[0] : null;
    }
  };

  /** EntryAbility.configureFlutterEngine 中调用：注册方法/事件双通道。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.methodChannel = new MethodChannel(messenger, METHOD_CHANNEL);
    this.methodChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(messenger, EVENT_CHANNEL);
    this.eventChannel.setStreamHandler(this);
    Log.i(TAG, '音频守卫桥就绪');
  }

  /** EntryAbility.onDestroy 中调用：注销原生监听并断开事件流。 */
  shutdown(): void {
    this.releaseListeners();
    this.sink = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'getMediaVolume') {
      result.success(this.readMediaVolume());
    } else {
      result.notImplemented();
    }
  }

  onListen(args: Any, events: EventSink): void {
    this.sink = events;
    this.lastVolume = -1;
    // 初始推送当前媒体音量（与 Android 侧 onListen 行为对齐，Dart 据此补判静音暂停）。
    const volume = this.readMediaVolume();
    if (volume !== null) {
      this.emitVolume(volume);
    }
    const audioManager = audio.getAudioManager();
    try {
      audioManager.getVolumeManager().on('volumeChange', this.onVolumeChange);
    } catch (e) {
      Log.e(TAG, `音量监听注册失败：${(e as BusinessError).code}`);
    }
    this.refreshActiveOutput();
    const routing = audioManager.getRoutingManager();
    try {
      routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, this.onDeviceChange);
    } catch (e) {
      Log.e(TAG, `设备监听注册失败：${(e as BusinessError).code}`);
    }
    try {
      routing.on('preferOutputDeviceChangeForRendererInfo', RENDERER_INFO, this.onPreferredChange);
    } catch (e) {
      Log.e(TAG, `首选输出监听注册失败：${(e as BusinessError).code}`);
    }
    Log.i(TAG, '音频守卫监听已注册');
  }

  onCancel(args: Any): void {
    this.releaseListeners();
    this.sink = null;
    Log.i(TAG, '音频守卫监听已注销');
  }

  /** 注销全部原生监听并清空活跃输出缓存（onCancel / shutdown 共用）。 */
  private releaseListeners(): void {
    const audioManager = audio.getAudioManager();
    try {
      audioManager.getVolumeManager().off('volumeChange', this.onVolumeChange);
    } catch (e) {
      Log.w(TAG, `音量监听注销失败：${(e as BusinessError).code}`);
    }
    const routing = audioManager.getRoutingManager();
    try {
      routing.off('deviceChange', this.onDeviceChange);
    } catch (e) {
      Log.w(TAG, `设备监听注销失败：${(e as BusinessError).code}`);
    }
    try {
      routing.off('preferOutputDeviceChangeForRendererInfo', this.onPreferredChange);
    } catch (e) {
      Log.w(TAG, `首选输出监听注销失败：${(e as BusinessError).code}`);
    }
    this.activeOutput = null;
  }

  /** 当前媒体音量档位；读取失败返回 null（Dart 侧按「未知」忽略）。 */
  private readMediaVolume(): number | null {
    try {
      return audio.getAudioManager().getVolumeManager()
        .getVolumeGroupManagerSync(audio.DEFAULT_VOLUME_GROUP_ID)
        .getVolumeSync(audio.AudioVolumeType.MEDIA);
    } catch (e) {
      Log.w(TAG, `媒体音量读取失败：${(e as BusinessError).code}`);
      return null;
    }
  }

  /** 重新查询系统首选输出设备，更新活跃输出缓存。 */
  private refreshActiveOutput(): void {
    try {
      const devices = audio.getAudioManager().getRoutingManager()
        .getPreferredOutputDeviceForRendererInfoSync(RENDERER_INFO);
      this.activeOutput = devices.length > 0 ? devices[0] : null;
    } catch (e) {
      Log.w(TAG, `首选输出查询失败：${(e as BusinessError).code}`);
      this.activeOutput = null;
    }
  }

  /** 两描述符是否为同一输出设备（deviceType 须一致；id 为主，address 兜底）。 */
  private sameDevice(a: audio.AudioDeviceDescriptor, b: audio.AudioDeviceDescriptor | null): boolean {
    if (b === null) {
      return false;
    }
    if (a.deviceType !== b.deviceType) {
      return false;
    }
    return a.id === b.id || (a.address !== '' && a.address === b.address);
  }

  /** 设备是否仍在当前输出设备列表中（区分「用户主动切换」与「断连自动回退」）。 */
  private isDeviceOnline(d: audio.AudioDeviceDescriptor): boolean {
    try {
      return audio.getAudioManager().getRoutingManager()
        .getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG)
        .some((x: audio.AudioDeviceDescriptor): boolean => this.sameDevice(x, d));
    } catch (e) {
      Log.w(TAG, `输出设备列表查询失败：${(e as BusinessError).code}`);
      return false;
    }
  }

  /** 上报媒体音量档位（Map 负载经 StandardMessageCodec 编码，Dart 侧收到 Map）。 */
  private emitVolume(value: number): void {
    this.lastVolume = value;
    // 负载值只需 string|number；不用 ESObject 动态类型（严格 lint 在泛型实参处禁用）。
    const event: Map<string, string | number> = new Map();
    event.set('type', 'volume');
    event.set('value', value);
    this.sink?.success(event);
  }

  /** 上报活跃输出设备断开。 */
  private emitOutputLost(): void {
    const event: Map<string, string | number> = new Map();
    event.set('type', 'outputLost');
    this.sink?.success(event);
  }
}

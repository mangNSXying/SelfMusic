
import {
  FlutterAbility,
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { BusinessError } from '@kit.BasicServicesKit';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import AvSessionBridge from '../media/AvSessionBridge';
import PlatformBridge from '../platform/PlatformBridge';

const TAG = 'SelfMusicBoot';
/** 与 Dart 侧（ohos_bootstrap.dart）约定的启动上报通道。 */
const BOOT_CHANNEL = 'selfmusic/boot';
/** 与 Dart 侧（app_background.dart）约定的返回手势转后台通道。 */
const APP_CHANNEL = 'selfmusic/app';
/** 首次敲击时限：正常冷启动 main() 约 2-3 秒走完；敲击本身无害，宜早不宜迟。 */
const BOOT_TIMEOUT_MS = 1500;
/** 敲击间隔：1 秒——停滞时每秒冲开一次投递管线，恢复延迟约等于一个间隔。 */
const POKE_INTERVAL_MS = 1000;
/** 最多敲击次数（约 1 分钟覆盖）：超过后放弃并记录（避免无限打扰）。 */
const MAX_POKES = 60;

/** Dart → ArkTS：接收 main() 完成 runApp 后的 'ready' 上报。 */
class BootCallHandler implements MethodCallHandler {
  private onReady: () => void = () => {
  };

  constructor(onReady: () => void) {
    this.onReady = onReady;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'ready') {
      this.onReady();
      result.success(null);
    } else {
      result.notImplemented();
    }
  }
}

/** Dart → ArkTS：返回手势转后台（selfmusic/app 通道）。 */
class AppCallHandler implements MethodCallHandler {
  private readonly moveToBackground: () => void;

  constructor(moveToBackground: () => void) {
    this.moveToBackground = moveToBackground;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'moveToBackground') {
      this.moveToBackground();
      result.success(true);
    } else {
      result.notImplemented();
    }
  }
}

/** ArkTS → Dart：唤醒敲击的回执（收到回执 = Dart 事件循环在跑）。 */
class BootPokeResult implements MethodResult {
  success(_result: ESObject): void {
    Log.i(TAG, 'poke 收到 Dart 回执：事件循环已恢复');
  }

  error(code: string, message: string, _details: ESObject): void {
    Log.w(TAG, `poke 回执错误：${code} ${message}`);
  }

  notImplemented(): void {
    Log.w(TAG, 'poke 回执 notImplemented');
  }
}

/**
 * 启动看门狗（鸿蒙白屏防御核心，真机取证 2026-09-28 定稿）：
 *
 * flutter_ohos 引擎（HAR 1.0.0-4cbeea6a36f1）启动早期两个缺陷：
 * 1. Dart 侧平台消息回复停滞不投递，main() 的 await 挂起，白屏；
 * 2. Dart Timer 子系统启动即死亡且外部事件无法复活（1s 延迟 Timer 在
 *    看门狗消息反复唤醒消息通道的情况下始终未触发，实测 5 轮）。
 *
 * 实测恢复机制（2026-09-28 两轮验证）：向 Dart 发平台消息——poke 本身
 * 不能复活窗口期已丢失的回复（28 次 poke 实证），但 poke 时段的投递
 * 完全正常；因此 poke 的真正作用是触发 Dart 侧重发在途平台调用
 * （ohos_bootstrap 的 boot 通道 handler → nudgePending），重发的新回复
 * 产生于健康时段、可正常投递，main() 随即恢复。
 *
 * 看门狗策略：引擎启动后每秒向 Dart 发一次 poke（首次 1.5 秒），直到
 * 收到 main() 完成 runApp 后的 'ready' 上报（唯一成功信号）。正常启动
 * 约 1-2 次 poke 即解除，对用户不可见；停滞启动在首次 poke 后约百毫秒
 * 恢复。应用侧另保证 main() 链零 Timer 依赖（见 ohos_bootstrap.dart）。
 */
export default class EntryAbility extends FlutterAbility {
  private bootChannel: MethodChannel | null = null;
  private bootReady: boolean = false;
  private bootTimerId: number = -1;
  private pokeCount: number = 0;
  private avSessionBridge: AvSessionBridge | null = null;
  private platformBridge: PlatformBridge | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    this.setupBootWatchdog(flutterEngine)
    this.avSessionBridge = new AvSessionBridge(this.context);
    this.avSessionBridge.setup(flutterEngine)
    // 系统能力平台桥（常亮/本地文件/蓝牙，selfmusic/platform）。
    this.platformBridge = new PlatformBridge(this.context);
    this.platformBridge.setup(flutterEngine)
    // 返回手势转后台：moveAbilityToBackground 与 home 键等效，UIAbility 与
    // 进程存活、播放链路不中断（侧滑返回曾落进 Dart 桌面退出分支 exit(0)
    // 直接杀进程，无法后台播放，2026-09-29 用户反馈；安卓同修）。
    const appChannel = new MethodChannel(
      flutterEngine.getDartExecutor().getBinaryMessenger(), APP_CHANNEL);
    appChannel.setMethodCallHandler(new AppCallHandler((): void => {
      this.context.moveAbilityToBackground()
        .then((): void => {
          Log.i(TAG, '应用已移至后台（返回手势）');
        })
        .catch((err: BusinessError): void => {
          Log.w(TAG, `移至后台失败：${err.code} ${err.message}`);
        });
    }));
  }

  onDestroy(): void {
    if (this.bootTimerId >= 0) {
      clearTimeout(this.bootTimerId);
      this.bootTimerId = -1;
    }
    if (this.avSessionBridge) {
      this.avSessionBridge.shutdown();
      this.avSessionBridge = null;
    }
    if (this.platformBridge) {
      this.platformBridge.shutdown();
      this.platformBridge = null;
    }
    super.onDestroy();
  }

  private setupBootWatchdog(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.bootChannel = new MethodChannel(messenger, BOOT_CHANNEL);
    this.bootChannel.setMethodCallHandler(new BootCallHandler((): void => {
      this.onBootReady();
    }));
    this.bootTimerId = setTimeout((): void => {
      this.checkBoot();
    }, BOOT_TIMEOUT_MS);
    Log.i(TAG, `启动看门狗就绪：每 ${POKE_INTERVAL_MS}ms poke 一次，等待 Dart ready`);
  }

  private onBootReady(): void {
    if (this.bootReady) {
      return;
    }
    this.bootReady = true;
    if (this.bootTimerId >= 0) {
      clearTimeout(this.bootTimerId);
      this.bootTimerId = -1;
    }
    Log.i(TAG, 'Dart 启动就绪（ready），看门狗解除');
  }

  private checkBoot(): void {
    if (this.bootReady) {
      return;
    }
    this.pokeCount += 1;
    const waited = BOOT_TIMEOUT_MS + (this.pokeCount - 1) * POKE_INTERVAL_MS;
    Log.w(TAG, `启动 ${waited}ms 未见 ready，向 Dart 发 poke（触发在途调用重发）${this.pokeCount}/${MAX_POKES}`);
    this.bootChannel?.invokeMethod('poke', null, new BootPokeResult());
    if (this.pokeCount < MAX_POKES) {
      this.bootTimerId = setTimeout((): void => {
        this.checkBoot();
      }, POKE_INTERVAL_MS);
    } else {
      Log.e(TAG, '多次唤醒敲击后仍无 ready，看门狗放弃（应用可能仍白屏）');
    }
  }
}

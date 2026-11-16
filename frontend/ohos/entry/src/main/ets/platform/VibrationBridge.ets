import {
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'SelfMusicVibration';
/** 与 Dart 侧（haptics.dart）约定的触感通道；与 Android 同名，Dart 解码零分叉。 */
const VIBRATION_CHANNEL = 'com.shamiko.selfmusic/vibration';

/**
 * 触感反馈桥（对照 Android VibrationController，设置→界面→交互）。
 *
 * 通道协议（Dart → ArkTS）：
 * - hasVibrator → boolean
 * - vibrate {durationMs, amplitude?} → boolean（振幅鸿蒙时间型振动不支持，忽略）
 * - cancel → null
 *
 * usage='touch'：由系统「触感反馈」开关管控，与系统 UI 行为一致。
 * 权限 ohos.permission.VIBRATE 为 system_grant，免运行时申请。
 * 所有失败一律回 false，不向 Dart 抛错。
 */
export default class VibrationBridge implements MethodCallHandler {
  private channel: MethodChannel | null = null;

  /** EntryAbility.configureFlutterEngine 中调用：注册方法通道。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.channel = new MethodChannel(messenger, VIBRATION_CHANNEL);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, '触感反馈桥就绪');
  }

  /** EntryAbility.onDestroy 中调用：断开通道。 */
  shutdown(): void {
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'hasVibrator') {
      result.success(this.hasVibrator());
      return;
    }
    if (call.method === 'vibrate') {
      this.vibrate(call, result).catch((): void => {
        // 内部已全量兜底，此处仅满足 Promise 必须处理。
      });
      return;
    }
    if (call.method === 'cancel') {
      this.cancel(result).catch((): void => {
        // 同上：失败已回 success(null)。
      });
      return;
    }
    result.notImplemented();
  }

  private hasVibrator(): boolean {
    try {
      // API 19+：返回本机振动器列表；旧系统无该接口时回退 true，
      // 由首次 startVibration 失败自然降级（Dart 侧仍判为无马达）。
      const infos: vibrator.VibratorInfo[] = vibrator.getVibratorInfoSync();
      return infos.length > 0;
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `探测振动器失败，按有马达处理：${err.code} ${err.message}`);
      return true;
    }
  }

  private async vibrate(call: MethodCall, result: MethodResult): Promise<void> {
    const durationMs = call.argument('durationMs') as number | null;
    if (durationMs === null || durationMs <= 0) {
      result.success(false);
      return;
    }
    try {
      await vibrator.startVibration({
        type: 'time',
        duration: durationMs
      }, {
        id: 0,
        usage: 'touch'
      });
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `震动失败：${err.code} ${err.message}`);
      result.success(false);
    }
  }

  private async cancel(result: MethodResult): Promise<void> {
    try {
      await vibrator.stopVibration(vibrator.VibratorStopMode.VIBRATOR_STOP_MODE_TIME);
      result.success(null);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `停止震动失败：${err.code} ${err.message}`);
      result.success(null);
    }
  }
}

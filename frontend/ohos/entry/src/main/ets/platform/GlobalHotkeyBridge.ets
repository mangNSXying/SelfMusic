import {
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { BusinessError } from '@kit.BasicServicesKit';
import { inputConsumer } from '@kit.InputKit';

const TAG = 'SelfMusicGlobalHotkey';
/** 与 Dart 侧（ohos_global_hotkeys.dart）约定的全局快捷键通道。 */
const GLOBAL_HOTKEY_CHANNEL = 'selfmusic/global_hotkeys';
/** 与 Dart 侧一致：组合键的修饰键数量上限（inputConsumer 支持 1~4 个）。 */
const MAX_PRE_KEYS = 4;

/** 一个已注册的组合键：注销时 off 必须使用同一 options 与 callback 引用。 */
interface HotkeyEntry {
  id: string;
  options: inputConsumer.HotkeyOptions;
  callback: (event: inputConsumer.HotkeyOptions) => void;
}

/**
 * 鸿蒙系统级全局快捷键桥（对照桌面端 hotkey_manager，2026-10-25）。
 *
 * 通道协议（selfmusic/global_hotkeys，Dart → ArkTS）：
 * - register {id:string,key:number,preKeys:number[]} → null
 *   id 为 ShortcutAction.name；key/preKeys 为
 *   @ohos.multimodalInput.keyCode.KeyCode 数值。inputConsumer.on 抛出的
 *   BusinessError（4200002 系统占用 / 4200003 已被其他应用订阅 / 801 不支持）
 *   原样转成 PlatformException，Dart 侧按单个绑定降级并记录日志。
 * - unregisterAll {} → null
 *   off 使用注册时保存的 options/callback 引用，避免注销错配。
 *
 * ArkTS → Dart：
 * - triggered <id>：组合键触发，Dart 侧解析为 ShortcutAction 并执行。
 *
 * 权限：inputConsumer.on('hotkeyChange') 官方接口无需声明权限；不要添加
 * INPUT_MONITORING / HOOK_KEY_EVENT（后者是系统级按键拦截权限）。应用退到
 * 后台后回调依赖进程存活（本应用已有 KEEP_BACKGROUND_RUNNING 播放链路）。
 */
export default class GlobalHotkeyBridge implements MethodCallHandler {
  private channel: MethodChannel | null = null;
  private readonly entries: HotkeyEntry[] = [];

  /** EntryAbility.configureFlutterEngine 中调用：注册方法通道。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.channel = new MethodChannel(messenger, GLOBAL_HOTKEY_CHANNEL);
    this.channel.setMethodCallHandler(this);
    const supported = canIUse(
      'SystemCapability.MultimodalInput.Input.InputConsumer');
    Log.i(TAG, `全局快捷键桥就绪（InputConsumer=${supported}）`);
  }

  /** EntryAbility.onDestroy 中调用：注销全部系统监听并断开通道。 */
  shutdown(): void {
    this.releaseAll();
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'register':
        this.handleRegister(call, result);
        break;
      case 'unregisterAll':
        this.releaseAll();
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private handleRegister(call: MethodCall, result: MethodResult): void {
    if (!canIUse('SystemCapability.MultimodalInput.Input.InputConsumer')) {
      result.error('801', '当前设备不支持全局快捷键（InputConsumer）', null);
      return;
    }
    const id = call.argument('id') as string | null;
    const key = call.argument('key') as number | null;
    const rawPreKeys = call.argument('preKeys') as number[] | null;
    if (id === null || id === '') {
      result.error('401', '缺少快捷键 id', null);
      return;
    }
    if (key === null || !Number.isInteger(key) || key <= 0) {
      result.error('401', '快捷键 key 非法', null);
      return;
    }
    if (rawPreKeys === null || !Array.isArray(rawPreKeys) ||
      rawPreKeys.length < 1 || rawPreKeys.length > MAX_PRE_KEYS) {
      result.error('401', '快捷键 preKeys 数量非法（需 1~4 个）', null);
      return;
    }
    const preKeys: number[] = [];
    for (const preKey of rawPreKeys) {
      if (typeof preKey !== 'number' || !Number.isInteger(preKey)) {
        result.error('401', '快捷键 preKeys 含非法值', null);
        return;
      }
      preKeys.push(preKey);
    }

    // 同 id 重复注册（设置变更/热重载）先移除旧监听，避免同一组合键双触发。
    this.unregisterById(id);
    const options: inputConsumer.HotkeyOptions = {
      preKeys: preKeys,
      finalKey: key,
      isRepeat: false
    };
    const callback = (_event: inputConsumer.HotkeyOptions): void => {
      try {
        this.channel?.invokeMethod('triggered', id);
      } catch (e) {
        const err = e as BusinessError;
        Log.w(TAG, `全局快捷键触发投递失败 ${id}: ${err.code} ${err.message}`);
      }
    };
    try {
      inputConsumer.on('hotkeyChange', options, callback);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `注册全局快捷键失败 ${id}: ${err.code} ${err.message}`);
      result.error(`${err.code}`, err.message, null);
      return;
    }
    this.entries.push({ id: id, options: options, callback: callback });
    result.success(null);
  }

  private unregisterById(id: string): void {
    for (let i = this.entries.length - 1; i >= 0; i--) {
      const entry = this.entries[i];
      if (entry.id !== id) {
        continue;
      }
      this.releaseEntry(entry);
      this.entries.splice(i, 1);
    }
  }

  private releaseAll(): void {
    for (const entry of this.entries) {
      this.releaseEntry(entry);
    }
    this.entries.length = 0;
  }

  private releaseEntry(entry: HotkeyEntry): void {
    try {
      inputConsumer.off('hotkeyChange', entry.options, entry.callback);
    } catch (e) {
      const err = e as BusinessError;
      Log.w(TAG, `注销全局快捷键失败 ${entry.id}: ${err.code} ${err.message}`);
    }
  }
}

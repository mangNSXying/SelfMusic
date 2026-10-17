
import {
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';

const TAG = 'SelfMusicEmailShare';
/** 与 Dart 侧（email_share.dart）约定的反馈邮件通道。 */
const EMAIL_CHANNEL = 'selfmusic/email';

/**
 * 反馈附件桥（对照 Android 端 share 通道）：鸿蒙无「mailto + 附件」协议，
 * 统一走 systemShare 系统分享面板携带日志文件（用户在面板中选择邮件类
 * 应用即完成带附件起草；分享框架自动授予文件读取权限，无需声明权限）。
 *
 * 通道协议（selfmusic/email，Dart → ArkTS）：
 * - sendEmailWithAttachment {to,subject,body,attachmentPath} → bool
 *   true=面板已拉起；false=文件缺失/面板拉起失败（Dart 侧回退 mailto 流程）。
 *
 * 说明：subject/body 作为面板标题/描述展示（鸿蒙分享框架语义，落进邮件
 * 客户端后是否变为主题/正文由对端应用决定）；to 参数暂未使用（分享面板
 * 阶段无法预填收件人），保留以对齐跨平台通道契约。
 */
export default class EmailShareBridge implements MethodCallHandler {
  private readonly context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** EntryAbility.configureFlutterEngine 中调用：注册方法通道。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.channel = new MethodChannel(messenger, EMAIL_CHANNEL);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, '反馈附件桥就绪');
  }

  /** EntryAbility.onDestroy 中调用：断开通道。 */
  shutdown(): void {
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'sendEmailWithAttachment') {
      this.sendEmailWithAttachment(call, result)
        .catch((): void => {
          // handler 内部全量兜底，此处仅为满足 Promise 必须处理。
        });
    } else {
      result.notImplemented();
    }
  }

  private async sendEmailWithAttachment(call: MethodCall, result: MethodResult): Promise<void> {
    const path = call.argument('attachmentPath') as string | null;
    const subject = call.argument('subject') as string | null;
    const body = call.argument('body') as string | null;
    if (path === null || path === '') {
      result.success(false);
      return;
    }
    try {
      const data = new systemShare.SharedData({
        // 与 .txt 日志文件匹配的 UTD 类型（general.text）。
        utd: utd.UniformDataType.PLAIN_TEXT,
        uri: fileUri.getUriFromPath(path),
        title: subject ?? '',
        description: body ?? ''
      });
      const controller = new systemShare.ShareController(data);
      // 分享面板挂在主窗口的 UIContext 上（Ability 层无页面 UIContext）。
      const win = await window.getLastWindow(this.context);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE
      };
      await controller.show(win.getUIContext(), options);
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `拉起分享面板失败：${err.code} ${err.message}`);
      result.success(false);
    }
  }
}

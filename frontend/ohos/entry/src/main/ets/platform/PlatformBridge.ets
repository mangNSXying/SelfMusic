
import {
  FlutterEngine,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { picker, fileShare, fileIo, ListFileOptions, ReadOptions, WriteOptions } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { connection, a2dp } from '@kit.ConnectivityKit';
import { taskpool } from '@kit.ArkTS';
import { ThumbDispatcher } from './ThumbDispatcher';
import { extractAudioMetaTask, AudioMetaResult } from './AudioMetaTask';

const TAG = 'SelfMusicPlatform';
/** 与 Dart 侧（ohos_platform_bridge.dart）约定的系统能力通道。 */
const PLATFORM_CHANNEL = 'selfmusic/platform';
/** readRange 单次读取上限（2 MiB 防御，Dart 侧按 512 KiB 分块调用）。 */
const READ_RANGE_MAX_BYTES = 2 * 1024 * 1024;
/** saveFile 复制日志的块大小（日志通常 < 1 MiB，分块避免整文件驻留内存）。 */
const SAVE_CHUNK_BYTES = 64 * 1024;

/** 文件级本地源：单次最多选择 500 个（API 20 及之前的上限，兼容鸿蒙 6）。 */
const PICK_FILE_MAX = 500;
/** persist/activate 单批上限（官方建议不超过 500，取 100 留余量）。 */
const GRANT_CHUNK_SIZE = 100;
/** 文件选择器的音频后缀过滤（与 Dart 侧 _audioExt 保持一致）。 */
const AUDIO_SUFFIX_FILTER = '音频|.mp3,.flac,.m4a,.aac,.ogg,.wav,.aif,.aiff,.aifc';

/** makeCoverThumb 参数缺省值（与 Dart 侧 kCoverThumbMaxEdge / kCoverThumbQuality 对齐）。 */
const THUMB_MAX_EDGE_DEFAULT = 768;
const THUMB_QUALITY_DEFAULT = 82;

/**
 * extractAudioMeta 并发上限（FR-007）：与缩略图生成（`ThumbDispatcher.maxInflight=2`）
 * 并存时的有界并发，避免两者相互挤占工作线程/主线程；Dart 侧补读队列本身串行，此闸门
 * 只兜住直接并发调用（播放链路 + 后台补读）。
 */
const META_MAX_INFLIGHT = 2;

/**
 * 有界并发闸门（信号量，宿主主线程侧使用）：`acquire` 在未达上限时立即放行，
 * 否则挂起直到 `release` 释放名额。仅用于 `extractAudioMeta` 的任务池派发。
 */
class MetaInflightGate {
  private readonly max: number;
  private active: number = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(max: number) {
    this.max = max < 1 ? 1 : max;
  }

  acquire(): Promise<void> {
    if (this.active < this.max) {
      this.active++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      this.waiters.push(resolve);
    });
  }

  release(): void {
    const next = this.waiters.shift();
    if (next !== undefined) {
      // 名额直接移交给下一个等待者（active 计数不变）。
      next();
      return;
    }
    if (this.active > 0) {
      this.active--;
    }
  }
}

/** listDirectory 单项结果（Dart 侧对应 OhosDirEntry）。 */
interface DirEntry {
  /** 目录内相对路径（fs.listFile recursion 返回值原样，以 / 开头）。 */
  rel: string;
  /** 文件大小（字节）。 */
  size: number;
  /** 上次修改时间（秒，与 Dart 侧指纹 mtime 语义一致）。 */
  mtime: number;
}

/** 文件多选结果（Dart 侧 OhosPickedFile）。 */
interface PickedFile {
  uri: string;
  name: string;
  size: number;
  mtime: number;
  /** 本次选择后是否成功持久化授权（false=仅本次会话可用）。 */
  persisted: boolean;
  /** 选择时是否可打开（false 仍返回，由扫描/界面提示）。 */
  readable: boolean;
}

/** 文件 URI stat 结果（Dart 侧 OhosFileStat）。 */
interface FileStat {
  uri: string;
  ok: boolean;
  size: number;
  mtime: number;
  code: string;
}

/**
 * 系统能力平台桥（2026-10-06 ohos-permissions feature；2026-10-06
 * ohos-thumb-native-decode feature 扩封面缩略图管线；2026-10-11
 * ohos-meta-enrich-native feature 扩音频元数据原生解析）：
 *
 * 承载鸿蒙端四项系统能力（对齐 Android 端已有行为，装配范式同
 * AvSessionBridge）：
 * - 常亮：keepScreenOn(enable) → window.setWindowKeepScreenOn（无需权限
 *   声明，仅前台生效；退后台随窗口失焦失效是系统预期行为）。
 * - 本地文件：系统目录选择器（DocumentViewPicker FOLDER）+ fileShare
 *   持久化授权（FILE_ACCESS_PERSIST，normal/system_grant 免弹窗）+
 *   fs.listFile 递归枚举 + fs.open/read 范围读，支撑「本地文件夹」
 *   音乐源选目录 → 扫描 → 点播 → 重启免重授全链路。
 * - 蓝牙：ACCESS_BLUETOOTH 场景化申请（三段式）+ 已配对/已连接音频
 *   设备查询，支撑「常亮限定蓝牙设备」门控轮询。
 * - 封面缩略图：makeCoverThumb 委托 `ThumbDispatcher`，缩略图管线（读图→EXIF
 *   方向→降采样→JPEG 重编码→原子落盘）在**任务池/Worker 独立线程**执行，
 *   UI 主线程只派发与收结果（ohos-thumb-taskpool feature，R-1/R-3/R-8）。
 *
 * 通道协议（selfmusic/platform，Dart → ArkTS，12 个方法，契约以 plan.md
 * 「Contracts & Interfaces」为准）：
 * - keepScreenOn {enable:bool} → null（窗口获取失败 error 上抛，Dart 记日志）
 * - pickDirectory {} → {uri,persisted} | null（用户取消 null；persistPermission
 *   失败返回 persisted=false，本次会话临时授权仍可用）
 * - activateDirectory {uri} → null（授权被撤销/目录删除 error 上抛）
 * - listDirectory {uri} → [{rel,size,mtime}]（rel 以 / 开头，mtime 秒）
 * - readRange {uri,rel,offset,length} → Uint8List（单次上限 2MiB 防御）
 * - resolvePath {uri,rel} → string（2026-10-07 播放管线修复：URI→沙箱真
 *   路径，播放 setFilePath 直连绕开 just_audio 本地代理；失败 error 上抛，
 *   Dart 侧回退字节流分支）
 * - requestBluetoothPermission {} → {granted:bool}（三段式，异常 granted=false）
 * - hasBluetoothPermission {} → bool（异常按 false）
 * - listBondedDevices {} → [{name,address}]（异常降级空数组 + 日志）
 * - connectedDevices {} → [address]（异常降级空数组 + 日志）
 * - makeCoverThumb {srcPath,thumbPath,maxEdge,quality} → {ok,costMs,degraded}
 *   （bool 语义兼容：ok 即原 bool）。**线程隔离（ohos-thumb-taskpool）**：本桥
 *   仅做参数校验并委托 `ThumbDispatcher`，缩略图管线（读图→EXIF→缩放→JPEG
 *   编码→tmp+rename 原子落盘）在任务池/Worker 独立线程执行，不再占用 UI 主
 *   线程（契约见 spec/ohos-thumb-taskpool plan.md R-1/R-3/R-8）。任何失败 ok=false，
 *   Dart 静默回原图显示，绝不向 Dart 抛错）
 * - extractAudioMeta {path,coverPath?} → {ok,title,artist,album,albumArtist,
 *   durationMs,genre,trackNo,year,coverPath,lyric,costMs,error}（2026-10-11
 *   ohos-meta-enrich-native feature）：标签解析/封面提取下沉 `AudioMetaTask.ets`
 *   的 `@Concurrent`（`AVMetadataExtractor`）在任务池执行，主线程只派发与收结果；
 *   有界并发 [META_MAX_INFLIGHT]。任何失败 ok=false（附 error），Dart 侧据此
 *   **不标已读**（既有重试语义）并回退既有 Dart 解析路径，绝不向 Dart 抛错。
 * - saveFile {suggestedName,sourcePath} → string | null（2026-10-20 日志导出
 *   修复）：`file_selector_ohos` 未实现 getDirectoryPath（pigeon 通道无处理
 *   器，调用必抛 channel-error），改用 DocumentViewPicker 保存模式选目标 +
 *   把沙箱临时日志复制到选择结果 URI。用户取消（13900042/空结果）回 null，
 *   真实失败 error 上抛，Dart 侧 toast。
 */
export default class PlatformBridge implements MethodCallHandler {
  private context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;
  /** extractAudioMeta 有界并发闸门（FR-007）。 */
  private readonly metaGate: MetaInflightGate = new MetaInflightGate(META_MAX_INFLIGHT);

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** EntryAbility.configureFlutterEngine 中调用。 */
  setup(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    this.channel = new MethodChannel(messenger, PLATFORM_CHANNEL);
    this.channel.setMethodCallHandler(this);
    Log.i(TAG, '平台桥就绪');
  }

  /** EntryAbility.onDestroy 中的资源回收。 */
  shutdown(): void {
    // 取消在飞缩略图任务 / 终止兜底 Worker（FR-009：不留半写产物）。
    ThumbDispatcher.getInstance().shutdown();
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'keepScreenOn':
        this.handleKeepScreenOn(call, result)
          .catch((): void => {
          });
        break;
      case 'supportsFolderSelection':
        this.handleSupportsFolderSelection(result);
        break;
      case 'pickDirectory':
        this.handlePickDirectory(result)
          .catch((): void => {
            // handler 内部全量兜底，此处仅为满足 Promise 必须处理。
          });
        break;
      case 'pickAudioFiles':
        this.handlePickAudioFiles(result)
          .catch((): void => {
            // handler 内部全量兜底，此处仅为满足 Promise 必须处理。
          });
        break;
      case 'activateUris':
        this.handleActivateUris(call, result)
          .catch((): void => {
          });
        break;
      case 'statFileUris':
        this.handleStatFileUris(call, result);
        break;
      case 'resolveFileUri':
        this.handleResolveFileUri(call, result);
        break;
      case 'readFileUriRange':
        this.handleReadFileUriRange(call, result)
          .catch((): void => {
          });
        break;
      case 'saveFile':
        this.handleSaveFile(call, result)
          .catch((): void => {
            // handler 内部全量兜底，此处仅为满足 Promise 必须处理。
          });
        break;
      case 'activateDirectory':
        this.handleActivateDirectory(call, result)
          .catch((): void => {
          });
        break;
      case 'listDirectory':
        this.handleListDirectory(call, result)
          .catch((): void => {
          });
        break;
      case 'readRange':
        this.handleReadRange(call, result)
          .catch((): void => {
          });
        break;
      case 'resolvePath':
        this.handleResolvePath(call, result);
        break;
      case 'requestBluetoothPermission':
        this.handleRequestBluetoothPermission(result)
          .catch((): void => {
          });
        break;
      case 'hasBluetoothPermission':
        this.handleHasBluetoothPermission(result)
          .catch((): void => {
          });
        break;
      case 'listBondedDevices':
        this.handleListBondedDevices(result);
        break;
      case 'connectedDevices':
        this.handleConnectedDevices(result);
        break;
      case 'makeCoverThumb':
        this.handleMakeCoverThumb(call, result)
          .catch((): void => {
          });
        break;
      case 'extractAudioMeta':
        this.handleExtractAudioMeta(call, result)
          .catch((): void => {
          });
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  // ---------- 常亮（US2） ----------

  /**
   * 播放页常亮开关：window.setWindowKeepScreenOn（无需权限声明，仅对
   * 前台主窗口生效；退后台随窗口失焦自动失效是系统预期行为，回前台由
   * Dart 侧按播放态重新拉起）。窗口获取失败 error 上抛，Dart 侧记日志
   * 降级（不中断播放）。
   */
  private async handleKeepScreenOn(call: MethodCall, result: MethodResult): Promise<void> {
    const enable = PlatformBridge.argBool(call, 'enable');
    if (enable == null) {
      result.error('401', '缺少 enable 参数', null);
      return;
    }
    try {
      const win = await window.getLastWindow(this.context);
      await win.setWindowKeepScreenOn(enable);
      Log.i(TAG, `keepScreenOn：${enable}`);
      result.success(null);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `keepScreenOn 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    }
  }

  // ---------- 本地文件（US1） ----------

  /**
   * 当前设备/系统是否支持系统目录选择（FOLDER）。
   *
   * `DocumentSelectMode.FOLDER` 在 Phone/Tablet 上从 API 26.0.0（鸿蒙 7）才开始
   * 生效，鸿蒙 6 手机/平板调用会让系统 FilePicker 弹出「功能未开放，敬请期待」。
   * Dart 侧在拉起目录选择器前必须先查本方法；不支持的设备改走
   * [`pickAudioFiles`] 的文件多选降级路线。
   */
  private handleSupportsFolderSelection(result: MethodResult): void {
    const supported: boolean =
      canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection');
    Log.i(TAG, `supportsFolderSelection：${supported}`);
    result.success(supported);
  }

  /**
   * 系统目录选择器（DocumentViewPicker FOLDER 模式，Phone 单选目录）+
   * 当场持久化授权。持久化必须趁选择器临时授权仍在存活的同一会话内完成
   * （临时授权随应用退出清除），因此选择与持久化在一步内收口。
   * 用户取消返回 null；持久化失败返回 persisted=false（本次会话临时授权
   * 仍可用）；对已持久化的 URI 重复调用按幂等成功处理。
   */
  private async handlePickDirectory(result: MethodResult): Promise<void> {
    // 防御：鸿蒙 6 手机/平板不支持 FOLDER，直接拉起会弹系统「功能未开放」。
    if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      result.error('801', '当前系统SDK无法选择文件夹，建议更新鸿蒙7', null);
      return;
    }
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      // 必须在 UIAbility 前台调用（选择器拉起系统 FilePicker 界面）。
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      const uris: Array<string> = await documentViewPicker.select(options);
      if (uris.length === 0) {
        Log.i(TAG, 'pickDirectory：用户取消');
        result.success(null);
        return;
      }
      const uri = uris[0];
      const persisted = await this.persistDirectoryGrant(uri);
      const out: Record<string, Object> = {
        'uri': uri,
        'persisted': persisted
      };
      Log.i(TAG, `pickDirectory：${uri}（persisted=${persisted}）`);
      result.success(out);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `pickDirectory 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    }
  }

  /**
   * persistPermission + 幂等处理：失败时用 checkPersistentPermission 复核，
   * 已持久化则按成功对待（重复选择同一目录的场景）。
   */
  private async persistDirectoryGrant(uri: string): Promise<boolean> {
    const policy: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE
    };
    const policies: Array<fileShare.PolicyInfo> = [policy];
    try {
      await fileShare.persistPermission(policies);
      return true;
    } catch (err) {
      const e = err as BusinessError<Array<fileShare.PolicyErrorResult>>;
      Log.w(TAG, `persistPermission 失败：${e.code} ${e.message}` +
        `${PlatformBridge.policyErrorDetail(e.data)}`);
    }
    try {
      const persisted: Array<boolean> =
        await fileShare.checkPersistentPermission(policies);
      if (persisted.length > 0 && persisted[0]) {
        Log.i(TAG, '目录此前已持久化，按幂等成功处理');
        return true;
      }
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `checkPersistentPermission 失败：${e.code} ${e.message}`);
    }
    return false;
  }

  /**
   * 文件多选（鸿蒙 6 手机/平板没有 FOLDER 能力时的降级入口）。
   *
   * 使用 `DocumentViewPicker` 的 FILE 模式 + 音频后缀过滤，避免
   * `AudioViewPicker` 返回媒体 URI（媒体 URI 的持久化从 API 22 才支持）。
   * 选择完成后立即逐 URI 持久化授权（分块），返回名称/大小/mtime/
   * persisted/readable，供 Dart 侧建立文件级本地源。
   */
  private async handlePickAudioFiles(result: MethodResult): Promise<void> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FILE;
      options.maxSelectNumber = PICK_FILE_MAX;
      options.fileSuffixFilters = [AUDIO_SUFFIX_FILTER];
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      let uris: Array<string> = [];
      try {
        uris = await documentViewPicker.select(options);
      } catch (err) {
        const e = err as BusinessError;
        // Picker 以 reject 表达取消（同 saveFile）。
        if (e.code === 13900042) {
          Log.i(TAG, 'pickAudioFiles：用户取消');
          result.success(null);
          return;
        }
        Log.e(TAG, `pickAudioFiles 选择失败：${e.code} ${e.message}`);
        result.error(`${e.code}`, e.message, null);
        return;
      }
      if (uris == null || uris.length === 0) {
        Log.i(TAG, 'pickAudioFiles：用户取消（空结果）');
        result.success(null);
        return;
      }
      const persisted: Array<boolean> = await this.persistUris(uris);
      const out: Array<PickedFile> = [];
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        let size = 0;
        let mtime = 0;
        let readable = false;
        let file: fileIo.File | null = null;
        try {
          file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
          const stat = fileIo.statSync(file.fd);
          size = stat.size;
          mtime = stat.mtime;
          readable = true;
        } catch (err) {
          const e = err as BusinessError;
          Log.w(TAG, `pickAudioFiles stat 失败：${e.code} ${e.message}`);
        } finally {
          if (file != null) {
            fileIo.closeSync(file);
          }
        }
        const item: PickedFile = {
          'uri': uri,
          'name': PlatformBridge.fileNameFromUri(uri),
          'size': size,
          'mtime': mtime,
          'persisted': i < persisted.length && persisted[i],
          'readable': readable
        };
        out.push(item);
      }
      Log.i(TAG, `pickAudioFiles：${out.length} 个文件`);
      result.success(out);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `pickAudioFiles 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    }
  }

  /**
   * 批量持久化文件/目录授权：单批 [GRANT_CHUNK_SIZE] 个；整批失败时用
   * checkPersistentPermission 复核（重复选择同一批文件的幂等场景）。
   */
  private async persistUris(uris: Array<string>): Promise<Array<boolean>> {
    const out: Array<boolean> = [];
    for (let i = 0; i < uris.length; i++) {
      out.push(false);
    }
    for (let start = 0; start < uris.length; start += GRANT_CHUNK_SIZE) {
      const end = Math.min(start + GRANT_CHUNK_SIZE, uris.length);
      const policies: Array<fileShare.PolicyInfo> = [];
      for (let i = start; i < end; i++) {
        const policy: fileShare.PolicyInfo = {
          uri: uris[i],
          operationMode: fileShare.OperationMode.READ_MODE
        };
        policies.push(policy);
      }
      try {
        await fileShare.persistPermission(policies);
        for (let i = start; i < end; i++) {
          out[i] = true;
        }
      } catch (err) {
        const e = err as BusinessError<Array<fileShare.PolicyErrorResult>>;
        Log.w(TAG, `persistUris 失败：${e.code} ${e.message}` +
          `${PlatformBridge.policyErrorDetail(e.data)}`);
        try {
          const checked: Array<boolean> =
            await fileShare.checkPersistentPermission(policies);
          for (let i = start; i < end; i++) {
            const j = i - start;
            if (j < checked.length && checked[j]) {
              out[i] = true;
            }
          }
        } catch (checkErr) {
          const ce = checkErr as BusinessError;
          Log.w(TAG, `persistUris checkPersistentPermission 失败：${ce.code} ${ce.message}`);
        }
      }
    }
    return out;
  }

  /**
   * 批量激活已持久化的文件 URI（进程重启后必须激活才能访问）。
   * 返回与入参同序的 boolean；整块失败时逐条重试，避免单个坏 URI 拖垮
   * 同批其它文件。
   */
  private async handleActivateUris(call: MethodCall, result: MethodResult): Promise<void> {
    const uris = PlatformBridge.argStringArray(call, 'uris');
    if (uris == null || uris.length === 0) {
      result.error('401', '缺少 uris 参数', null);
      return;
    }
    const out: Array<boolean> = [];
    for (let i = 0; i < uris.length; i++) {
      out.push(false);
    }
    for (let start = 0; start < uris.length; start += GRANT_CHUNK_SIZE) {
      const end = Math.min(start + GRANT_CHUNK_SIZE, uris.length);
      const policies: Array<fileShare.PolicyInfo> = [];
      for (let i = start; i < end; i++) {
        const policy: fileShare.PolicyInfo = {
          uri: uris[i],
          operationMode: fileShare.OperationMode.READ_MODE
        };
        policies.push(policy);
      }
      try {
        await fileShare.activatePermission(policies);
        for (let i = start; i < end; i++) {
          out[i] = true;
        }
      } catch (err) {
        const e = err as BusinessError<Array<fileShare.PolicyErrorResult>>;
        Log.w(TAG, `activateUris 批量失败，逐条重试：${e.code} ${e.message}` +
          `${PlatformBridge.policyErrorDetail(e.data)}`);
        for (let i = start; i < end; i++) {
          const policy: fileShare.PolicyInfo = {
            uri: uris[i],
            operationMode: fileShare.OperationMode.READ_MODE
          };
          try {
            await fileShare.activatePermission([policy]);
            out[i] = true;
          } catch (oneErr) {
            const oe = oneErr as BusinessError;
            Log.w(TAG, `activateUris 失败：${uris[i]} ${oe.code} ${oe.message}`);
          }
        }
      }
    }
    Log.i(TAG, `activateUris：${out.filter((v: boolean): boolean => v).length}/${uris.length}`);
    result.success(out);
  }

  /** 批量 stat 文件 URI（名称/大小/mtime 由 Dart 侧用于扫描 diff）。 */
  private handleStatFileUris(call: MethodCall, result: MethodResult): void {
    const uris = PlatformBridge.argStringArray(call, 'uris');
    if (uris == null || uris.length === 0) {
      result.error('401', '缺少 uris 参数', null);
      return;
    }
    const out: Array<FileStat> = [];
    for (const uri of uris) {
      const item: FileStat = {
        'uri': uri,
        'ok': false,
        'size': 0,
        'mtime': 0,
        'code': ''
      };
      let file: fileIo.File | null = null;
      try {
        file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(file.fd);
        item.ok = true;
        item.size = stat.size;
        item.mtime = stat.mtime;
      } catch (err) {
        const e = err as BusinessError;
        item.code = e.code != null ? `${e.code}` : '500';
      } finally {
        if (file != null) {
          fileIo.closeSync(file);
        }
      }
      out.push(item);
    }
    result.success(out);
  }

  /** 文件 URI → 沙箱真路径（供播放 setFilePath 直连）。 */
  private handleResolveFileUri(call: MethodCall, result: MethodResult): void {
    const uri = PlatformBridge.argString(call, 'uri');
    if (uri == null || uri === '') {
      result.error('401', '缺少 uri 参数', null);
      return;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const path = file.path;
      if (path == null || path === '') {
        result.error('402', '文件 URI 解析沙箱路径失败（file.path 为空）', null);
        return;
      }
      Log.i(TAG, 'resolveFileUri：成功');
      result.success(path);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `resolveFileUri 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    } finally {
      if (file != null) {
        fileIo.closeSync(file);
      }
    }
  }

  /** 文件 URI 范围读（与目录 readRange 共用 [readRangeAt]）。 */
  private async handleReadFileUriRange(call: MethodCall,
    result: MethodResult): Promise<void> {
    const uri = PlatformBridge.argString(call, 'uri');
    const offset = PlatformBridge.argNumber(call, 'offset');
    const length = PlatformBridge.argNumber(call, 'length');
    if (uri == null || uri === '' || offset == null || offset < 0 || length == null) {
      result.error('401', 'readFileUriRange 参数非法', null);
      return;
    }
    if (length <= 0 || length > READ_RANGE_MAX_BYTES) {
      result.error('401',
        `readFileUriRange length 非法：${length}（上限 ${READ_RANGE_MAX_BYTES}）`, null);
      return;
    }
    await this.readRangeAt('readFileUriRange', uri, offset, length, result);
  }

  /** 目录 readRange / 文件 readFileUriRange 共用的精确范围读。 */
  private async readRangeAt(label: string, path: string, offset: number,
    length: number, result: MethodResult): Promise<void> {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(length);
      const options: ReadOptions = { offset: offset, length: length };
      const readLen = await fileIo.read(file.fd, buffer, options);
      if (readLen !== length) {
        result.error('13900030',
          `${label} 读取不完整：期望 ${length}，实际 ${readLen}`, null);
        return;
      }
      result.success(new Uint8Array(buffer));
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `${label} 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    } finally {
      if (file != null) {
        fileIo.closeSync(file);
      }
    }
  }

  // ---------- 日志导出（saveFile） ----------

  /**
   * 导出日志到用户选择的位置（2026-10-20 修复 channel-error）：鸿蒙
   * `file_selector_ohos` 的 `getDirectoryPath` 未实现（pigeon 通道无处理器，
   * Dart 调用必抛 `Unable to establish connection on channel.`），故「收集
   * 日志」改走本桥：
   * 1. DocumentViewPicker 保存模式（`newFileNames` 预填文件名）拉起系统
   *    文件保存界面，用户选目录/文件名；
   * 2. 用户取消（13900042/空结果）返回 null，不算失败；
   * 3. 选择结果 URI 当场仍有临时写授权，把 Dart 侧已写好的沙箱临时日志
   *    分块复制过去，返回保存 URI（Dart 侧展示）。
   *
   * 失败（选择器不可用/目标不可写）error 上抛，由 Dart 侧 toast
   * 「日志导出失败」。
   */
  private async handleSaveFile(call: MethodCall, result: MethodResult): Promise<void> {
    const suggestedName = PlatformBridge.argString(call, 'suggestedName');
    const sourcePath = PlatformBridge.argString(call, 'sourcePath');
    if (suggestedName == null || suggestedName === '' ||
      sourcePath == null || sourcePath === '') {
      result.error('401', 'saveFile 参数非法', null);
      return;
    }
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [suggestedName];
      // 必须在 UIAbility 前台调用（选择器拉起系统 FilePicker 界面）。
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      const uris: Array<string> = await documentViewPicker.save(options);
      if (uris == null || uris.length === 0) {
        Log.i(TAG, 'saveFile：用户取消（空结果）');
        result.success(null);
        return;
      }
      const savedUri = uris[0];
      const copied = await this.copyFileToUri(sourcePath, savedUri);
      if (!copied) {
        result.error('500', '日志写入目标文件失败', null);
        return;
      }
      Log.i(TAG, `saveFile：已保存 ${savedUri}`);
      result.success(savedUri);
    } catch (err) {
      const e = err as BusinessError;
      // 13900042：用户取消选择（Picker 以 reject 表达取消，属正常路径）。
      if (e.code === 13900042) {
        Log.i(TAG, 'saveFile：用户取消');
        result.success(null);
        return;
      }
      Log.e(TAG, `saveFile 失败：${e.code} ${e.message}`);
      const code = e.code != null ? `${e.code}` : '500';
      const message = e.message != null ? e.message : JSON.stringify(err);
      result.error(code, message, null);
    }
  }

  /** 沙箱临时日志 → 选择器返回的 URI（分块复制；返回是否完整写入）。 */
  private async copyFileToUri(sourcePath: string, destUri: string): Promise<boolean> {
    let src: fileIo.File | null = null;
    let dst: fileIo.File | null = null;
    try {
      src = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      dst = fileIo.openSync(destUri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const size = fileIo.statSync(src.fd).size;
      const buffer = new ArrayBuffer(SAVE_CHUNK_BYTES);
      let offset = 0;
      while (offset < size) {
        const want = Math.min(SAVE_CHUNK_BYTES, size - offset);
        const readOptions: ReadOptions = { offset: offset, length: want };
        const readLen = await fileIo.read(src.fd, buffer, readOptions);
        if (readLen <= 0) {
          return false;
        }
        const writeOptions: WriteOptions = { offset: offset, length: readLen };
        const writeLen = await fileIo.write(dst.fd, buffer, writeOptions);
        if (writeLen !== readLen) {
          return false;
        }
        offset += readLen;
      }
      return offset === size;
    } finally {
      if (src != null) {
        fileIo.closeSync(src);
      }
      if (dst != null) {
        fileIo.closeSync(dst);
      }
    }
  }

  /**
   * 重启后激活已持久化的目录授权（持久化数据在系统数据库中，每次启动
   * 需手动激活才生效）。授权被撤销/目录删除时 error 上抛，Dart 侧转译
   * 为「目录授权已失效，请编辑该源重新选择目录」。
   */
  private async handleActivateDirectory(call: MethodCall, result: MethodResult): Promise<void> {
    const uri = PlatformBridge.argString(call, 'uri');
    if (uri == null || uri === '') {
      result.error('401', '缺少 uri 参数', null);
      return;
    }
    const policy: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE
    };
    try {
      await fileShare.activatePermission([policy]);
      Log.i(TAG, 'activateDirectory：授权已激活');
      result.success(null);
    } catch (err) {
      const e = err as BusinessError<Array<fileShare.PolicyErrorResult>>;
      Log.e(TAG, `activateDirectory 失败：${e.code} ${e.message}` +
        `${PlatformBridge.policyErrorDetail(e.data)}`);
      result.error(`${e.code}`, e.message, null);
    }
  }

  /**
   * 递归枚举授权目录（快照，不打开音频文件）：fs.listFile(recursion) 返回
   * 以 / 开头的相对路径，逐项 fs.stat 组装 {rel, size, mtime}。全量返回，
   * 过滤/指纹 diff 由 Dart 侧公共函数处理（业务规则不进平台层）。
   *
   * 路径解析（2026-10-07 bug 修复）：fs.listFile / fs.stat 仅接受应用沙箱
   * 路径，不接受 URI（js-apis-file-fs 参数表）——直接把 docs URI 传入会得
   * 到 13900002 ENOENT（真机日志 [listfile.cpp RecursiveFunc] Failed to
   * scan dir）。官方转换方式：fs.openSync(uri) 得到 File，其 .path 即对应
   * 沙箱路径（FAQ faqs-local-file-manager-56 uri→sandboxPath 行）。故先
   * open（DIR 模式断言目录语义）取 path，再以 path 枚举与 stat。枚举期间
   * 保持 fd 打开，结束后关闭。
   */
  private async handleListDirectory(call: MethodCall, result: MethodResult): Promise<void> {
    const uri = PlatformBridge.argString(call, 'uri');
    if (uri == null || uri === '') {
      result.error('401', '缺少 uri 参数', null);
      return;
    }
    let dir: fileIo.File | null = null;
    try {
      dir = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR);
      const dirPath = dir.path;
      if (dirPath == null || dirPath === '') {
        // 防御：文档未保证 URI open 必有 path；显式报错避免误判为授权问题。
        result.error('402', '目录 URI 解析沙箱路径失败（file.path 为空）', null);
        return;
      }
      const options: ListFileOptions = { recursion: true };
      const names: Array<string> = await fileIo.listFile(dirPath, options);
      const out: Array<DirEntry> = [];
      for (const rel of names) {
        // dirPath+rel 直接拼接（rel 以 / 开头），不做二次编码。
        const stat = await fileIo.stat(dirPath + rel);
        const entry: DirEntry = {
          rel: rel,
          size: stat.size,
          mtime: stat.mtime
        };
        out.push(entry);
      }
      result.success(out);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `listDirectory 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    } finally {
      if (dir != null) {
        fileIo.closeSync(dir);
      }
    }
  }

  /**
   * 范围读授权目录内文件：fs.open READ_ONLY + fs.read 指定 offset/length。
   * 单次上限 2 MiB（防御）；读取不完整/文件缺失 error 上抛，Dart 播放侧
   * 按打开失败处理。
   */
  private async handleReadRange(call: MethodCall, result: MethodResult): Promise<void> {
    const uri = PlatformBridge.argString(call, 'uri');
    const rel = PlatformBridge.argString(call, 'rel');
    const offset = PlatformBridge.argNumber(call, 'offset');
    const length = PlatformBridge.argNumber(call, 'length');
    if (uri == null || uri === '' || rel == null || rel === '' ||
      offset == null || offset < 0 || length == null) {
      result.error('401', 'readRange 参数非法', null);
      return;
    }
    if (length <= 0 || length > READ_RANGE_MAX_BYTES) {
      result.error('401', `readRange length 非法：${length}（上限 ${READ_RANGE_MAX_BYTES}）`, null);
      return;
    }
    await this.readRangeAt('readRange', uri + rel, offset, length, result);
  }

  /**
   * 解析授权目录内文件的沙箱真路径（2026-10-07 播放管线修复）：
   * `openSync(uri)` 仅 URI 授权会话内可开，而 `.path` 是对应沙箱真实路径，
   * 进程内原生代码（mdk/FFmpeg file:// 播放）可直接打开。供 Dart 侧
   * cachedFilePath 的 ohos 分支使用——播放走 setFilePath 直连，不再经过
   * just_audio 本地代理（真机取证：代理对死锁后 socket 事件通知以 ~305µs
   * 周期空转，~2.9k HandleMessage/s 烧 ~1.5 核 CPU，netstat 见收发双向
   * MB 级积压的环回 ESTABLISHED 对）。
   * 打开失败（授权被撤销/文件被删）error 上抛，Dart 侧回退字节流分支。
   */
  private handleResolvePath(call: MethodCall, result: MethodResult): void {
    const uri = PlatformBridge.argString(call, 'uri');
    const rel = PlatformBridge.argString(call, 'rel');
    if (uri == null || uri === '' || rel == null || rel === '') {
      result.error('401', 'resolvePath 参数非法', null);
      return;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri + rel, fileIo.OpenMode.READ_ONLY);
      const path = file.path;
      if (path == null || path === '') {
        // 防御：文档未保证 URI open 必有 path（同 listDirectory 的 402）。
        result.error('402', '文件 URI 解析沙箱路径失败（file.path 为空）', null);
        return;
      }
      Log.i(TAG, `resolvePath：${rel}`);
      result.success(path);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `resolvePath 失败：${e.code} ${e.message}`);
      result.error(`${e.code}`, e.message, null);
    } finally {
      if (file != null) {
        fileIo.closeSync(file);
      }
    }
  }

  // ---------- 蓝牙（US3） ----------

  /**
   * ACCESS_BLUETOOTH 三段式场景化申请（FR-009：仅常亮限定设备设置页触发，
   * 启动期零权限）：
   * 1. requestPermissionsFromUser：authResults[0]===0 即已授权；
   * 2. 未授权（本次弹窗被拒 dialogShownResults[0]===true，或历史拒绝静默
   *    返回 false）→ requestPermissionOnSetting 拉起带「去设置」入口的
   *    授权弹窗，二次给用户机会；
   * 3. 全部未授权/异常（201 未声明、801 设备不支持）→ granted=false，
   *    Dart 侧降级（蓝牙门控按无设备处理），不阻断设置流程。
   */
  private async handleRequestBluetoothPermission(result: MethodResult): Promise<void> {
    const perms: Array<Permissions> = ['ohos.permission.ACCESS_BLUETOOTH'];
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const res = await atManager.requestPermissionsFromUser(this.context, perms);
      if (res.authResults.length > 0 &&
        res.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        Log.i(TAG, 'requestBluetoothPermission：已授权');
        result.success(PlatformBridge.grantedResult(true));
        return;
      }
      // 弹窗被拒/静默拒绝 → 设置弹窗兜底（authResults 与 dialogShownResults
      // 同序，两者取 [0] 对应同一权限）。
      const grant: Array<abilityAccessCtrl.GrantStatus> =
        await atManager.requestPermissionOnSetting(this.context, perms);
      const granted = grant.length > 0 &&
        grant[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      Log.i(TAG, `requestBluetoothPermission：requestPermissionOnSetting=${granted}`);
      result.success(PlatformBridge.grantedResult(granted));
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `requestBluetoothPermission 失败：${e.code} ${e.message}`);
      result.success(PlatformBridge.grantedResult(false));
    }
  }

  /** 授权状态查询（checkAccessToken）：异常与未授权一律 false。 */
  private async handleHasBluetoothPermission(result: MethodResult): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.appInfo?.accessTokenId ?? 0;
      if (tokenId === 0) {
        result.success(false);
        return;
      }
      const status = await atManager.checkAccessToken(
        tokenId, 'ohos.permission.ACCESS_BLUETOOTH');
      result.success(status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `hasBluetoothPermission 失败：${e.code} ${e.message}`);
      result.success(false);
    }
  }

  /**
   * 已配对设备列表（getPairedDevices 返回虚拟 MAC）：{name,address} 列表
   * 供「常亮限定蓝牙设备」候选；蓝牙未开启等异常降级空数组 + 日志
   * （Dart 侧无须感知错误细节）。
   */
  private handleListBondedDevices(result: MethodResult): void {
    try {
      const devices: Array<string> = connection.getPairedDevices();
      const out: Array<Record<string, Object>> = [];
      for (const address of devices) {
        const item: Record<string, Object> = {
          'name': connection.getRemoteDeviceName(address),
          'address': address
        };
        out.push(item);
      }
      result.success(out);
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `listBondedDevices 失败：${e.code} ${e.message}`);
      result.success([]);
    }
  }

  /**
   * 已连接的 A2DP 音频设备（getConnectedDevices 返回虚拟 MAC 列表）：
   * 蓝牙门控轮询用；蓝牙未开启（2900001）/开关中（2900003）等异常一律
   * 降级空数组——语义为「无常亮限定设备在连」，与业务降级方向一致。
   */
  private handleConnectedDevices(result: MethodResult): void {
    try {
      const profile = a2dp.createA2dpSrcProfile();
      const devices: Array<string> = profile.getConnectedDevices();
      result.success(devices);
    } catch (err) {
      const e = err as BusinessError;
      Log.w(TAG, `connectedDevices 失败：${e.code} ${e.message}`);
      result.success([]);
    }
  }

  // ---------- 封面缩略图（ohos-thumb-native-decode / ohos-thumb-taskpool） ----------

  /**
   * 封面缩略图生成（**线程隔离版**，契约见 spec/ohos-thumb-taskpool plan.md
   * R-1/R-3/R-8）：本方法仅做**参数校验 + 调度委托**，不再在 UI 主线程内联执行
   * 解码/编码/写盘（原实现见历史，管线已迁至无 UI 依赖的 `ThumbTask.ets`）：
   * 1. 参数校验（srcPath/thumbPath 非空；maxEdge/quality 缺省回退 768/82，越界回退缺省）；
   * 2. 委托 `ThumbDispatcher.generate`——有界并发 + 同目标去重，首选 TaskPool，
   *    目标设备不可用时降级 Worker 独立线程（降级经 hilog 可观测，FR-008）；
   * 3. 汇总结果为结构化 `{ok,costMs,degraded}` 回桥（ok 即原 bool 语义，R-8）。
   *
   * 任何失败 ok=false，Dart 静默回原图显示（FR-003），全程不向 Dart 抛未捕获错误。
   */
  private async handleMakeCoverThumb(call: MethodCall, result: MethodResult): Promise<void> {
    const srcPath = PlatformBridge.argString(call, 'srcPath');
    const thumbPath = PlatformBridge.argString(call, 'thumbPath');
    if (srcPath == null || srcPath === '' || thumbPath == null || thumbPath === '') {
      Log.w(TAG, 'makeCoverThumb：缺少 srcPath/thumbPath 参数');
      result.success(false);
      return;
    }
    const maxEdgeRaw = PlatformBridge.argNumber(call, 'maxEdge');
    const maxEdge = maxEdgeRaw != null && Number.isInteger(maxEdgeRaw) &&
      maxEdgeRaw > 0 && maxEdgeRaw <= 10000 ? maxEdgeRaw : THUMB_MAX_EDGE_DEFAULT;
    const qualityRaw = PlatformBridge.argNumber(call, 'quality');
    const quality = qualityRaw != null && Number.isInteger(qualityRaw) &&
      qualityRaw >= 1 && qualityRaw <= 100 ? qualityRaw : THUMB_QUALITY_DEFAULT;
    const r = await ThumbDispatcher.getInstance()
      .generate(srcPath, thumbPath, maxEdge, quality);
    const out: Record<string, Object> = {
      'ok': r.ok,
      'costMs': r.costMs,
      'degraded': r.degraded
    };
    result.success(out);
  }

  // ---------- 音频元数据原生解析（ohos-meta-enrich-native） ----------

  /**
   * 音频元数据原生解析（契约见 spec/ohos-meta-enrich-native plan.md R-1）。
   *
   * 参数校验（`path` 非空；`coverPath` 可选，''=不需要封面）→ 有界并发闸门 →
   * 任务池派发 `extractAudioMetaTask` → 结构化结果回桥。任何失败 `ok=false`
   * （附简短 error），**绝不向 Dart 抛错**。
   */
  private async handleExtractAudioMeta(call: MethodCall, result: MethodResult): Promise<void> {
    const path = PlatformBridge.argString(call, 'path');
    if (path == null || path === '') {
      result.success(PlatformBridge.metaFailMap('缺少 path 参数'));
      return;
    }
    const coverPath = PlatformBridge.argString(call, 'coverPath') ?? '';
    await this.metaGate.acquire();
    try {
      const out = await this.runExtractAudioMeta(path, coverPath);
      result.success(out);
    } catch (err) {
      const e = err as Error;
      Log.w(TAG, `extractAudioMeta 失败：${e.message}`);
      result.success(PlatformBridge.metaFailMap(e.message));
    } finally {
      this.metaGate.release();
    }
  }

  /**
   * 调度委托：`taskpool` 执行 `extractAudioMetaTask`（有界并发由 [metaGate]
   * 保证）。`taskpool.execute` 抛错表示**并发机制**不可用（目标设备 TaskPool
   * 受限 / 并发函数内媒体能力受限等）→ 返回 `ok=false`，Dart 侧据此**不标已读**
   * 并回退既有 Dart 解析路径（保收敛，绝不向 Dart 抛错）。
   */
  private async runExtractAudioMeta(path: string,
    coverPath: string): Promise<Record<string, Object>> {
    try {
      const task = new taskpool.Task(extractAudioMetaTask, path, coverPath);
      const raw: Object = await taskpool.execute(task);
      const r = raw as AudioMetaResult;
      return PlatformBridge.metaResultToMap(r);
    } catch (err) {
      const e = err as Error;
      Log.w(TAG, `extractAudioMeta 并发执行失败：${e.message}`);
      return PlatformBridge.metaFailMap(`并发执行失败：${e.message}`);
    }
  }

  /** extractAudioMeta 失败结果（全字段缺省 + error 摘要，契约形态稳定）。 */
  private static metaFailMap(error: string): Record<string, Object> {
    return PlatformBridge.metaMap(false, '', '', '', '', 0, '', 0, 0, '', '', 0, error);
  }

  /** 原生结果 → 通道可序列化 Map（字段名与 Dart 侧 OhosAudioMetaResult 对齐）。 */
  private static metaResultToMap(r: AudioMetaResult): Record<string, Object> {
    return PlatformBridge.metaMap(r.ok, r.title, r.artist, r.album, r.albumArtist,
      r.durationMs, r.genre, r.trackNo, r.year, r.coverPath, r.lyric, r.costMs, r.error);
  }

  /** 统一的通道结果组装（集中字段口径，避免逐处拼装漂移）。 */
  private static metaMap(ok: boolean, title: string, artist: string, album: string,
    albumArtist: string, durationMs: number, genre: string, trackNo: number,
    year: number, coverPath: string, lyric: string, costMs: number,
    error: string): Record<string, Object> {
    const out: Record<string, Object> = {
      'ok': ok,
      'title': title,
      'artist': artist,
      'album': album,
      'albumArtist': albumArtist,
      'durationMs': durationMs,
      'genre': genre,
      'trackNo': trackNo,
      'year': year,
      'coverPath': coverPath,
      'lyric': lyric,
      'costMs': costMs,
      'error': error
    };
    return out;
  }

  /**
   * persist/activate 失败时官方在异常 data:Array<PolicyErrorResult> 中
   * 给出逐 URI 失败原因（PERSISTENCE_FORBIDDEN/INVALID_MODE/INVALID_PATH/
   * PERMISSION_NOT_PERSISTED）；拼进日志——用户可见错误只有一条文案，
   * 真机定位全靠这段 detail（13900001 时必看）。
   */
  private static policyErrorDetail(
    data: Array<fileShare.PolicyErrorResult> | undefined): string {
    if (data === undefined || data.length === 0) {
      return '';
    }
    const parts: Array<string> = [];
    for (const r of data) {
      parts.push(`${r.uri}#${r.code}(${r.message})`);
    }
    return ` detail=[${parts.join('; ')}]`;
  }

  /** requestBluetoothPermission 的返回体 {granted:bool}。 */
  private static grantedResult(granted: boolean): Record<string, Object> {
    const out: Record<string, Object> = { 'granted': granted };
    return out;
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

  private static argStringArray(call: MethodCall, key: string): Array<string> | null {
    const arr = call.argument(key) as Array<string> | null;
    if (arr == null || !Array.isArray(arr)) {
      return null;
    }
    const out: Array<string> = [];
    for (const item of arr) {
      if (typeof item !== 'string' || item === '') {
        return null;
      }
      out.push(item);
    }
    return out;
  }

  /** 从 document URI 提取文件名（去掉 query/fragment，再做 decode）。 */
  private static fileNameFromUri(uri: string): string {
    let s = uri;
    const q = s.indexOf('?');
    if (q >= 0) {
      s = s.substring(0, q);
    }
    const h = s.indexOf('#');
    if (h >= 0) {
      s = s.substring(0, h);
    }
    const slash = s.lastIndexOf('/');
    const raw = slash >= 0 ? s.substring(slash + 1) : s;
    try {
      return decodeURIComponent(raw);
    } catch (err) {
      return raw;
    }
  }
}

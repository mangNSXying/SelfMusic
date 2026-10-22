import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 鸿蒙系统能力桥（Dart 侧，`selfmusic/platform` 通道封装）。
///
/// 与 ArkTS 侧 [PlatformBridge]（PlatformBridge.ets）配对，承载四项
/// 系统能力的通道调用（2026-10-06 ohos-permissions feature；
/// 2026-10-06 ohos-thumb-native-decode feature 扩封面缩略图管线，契约以
/// plan.md「Contracts & Interfaces」为准）：
/// - 常亮：[keepScreenOn] → window.setWindowKeepScreenOn；
/// - 本地文件：[pickDirectory]（选择器 + 持久化授权）→ [listDirectory]
///   （递归枚举）→ [readRange]（范围读）；持久化授权在进程重启后需先激活，
///   扫描/播放/补读的所有 URI 访问前统一经 [ensureDirectoryActivated]
///   幂等激活（同 URI 单飞 + 成功缓存）；
/// - 蓝牙：[requestBluetoothPermission] / [hasBluetoothPermission] /
///   [listBondedDevices] / [connectedDevices]；
/// - 封面缩略图：[makeCoverThumb]（@ohos.multimedia.image 原生管线——当时
///   `runOffThread` 在 ohos 内联（历史守卫，不是引擎不能 spawn 子 isolate），
///   纯 Dart 编码会阻塞 UI isolate；原生管线保留：系统解码/编码更快，且解码/
///   缩放/编码/写盘全部下沉 ArkTS 侧）；
/// - 音频元数据：[extractAudioMeta]（2026-10-11 ohos-meta-enrich-native feature
///   ——同样因当时 `runOffThread` 在 ohos 内联，纯 Dart 标签解析/封面提取会以
///   秒级同步块独占主线程，下沉 ArkTS `@Concurrent` 任务池的
///   `AVMetadataExtractor` 管线，Dart 只收结构化结果并落库；原生管线保留：
///   系统解析更快且不把大文件读进 Dart）；
/// - 日志导出：[saveFile]（2026-10-20）——`file_selector_ohos` 未实现
///   `getDirectoryPath`（pigeon 通道无处理器，调用必抛 channel-error），
///   改走 DocumentViewPicker 保存模式 + 原生复制。
///
/// 仅被 `isOhos` 分支调用（Android/桌面走各自实现，零回归）。
///
/// 异常处理约定：
/// - [pickDirectory]：用户取消/任何异常返回 null（调用方保持表单不动）；
/// - [activateDirectory] / [listDirectory]：异常向上抛，由调用方转译为
///   用户可见错误（「目录授权已失效，请编辑该源重新选择目录」）；
/// - [readRange]：异常向上抛，播放侧按打开失败处理；
/// - 蓝牙查询：异常返回空集合/false 并 debugPrint 诊断日志（对齐 Android
///   「按未连接判定」的静默降级语义）；
/// - [makeCoverThumb]：任何异常/超时/失败返回 false 并 debugPrint（缩略图
///   是纯优化，调用方静默回原图显示；绝不回退内联 Dart 编码）；
/// - [extractAudioMeta]：任何异常/超时/失败返回 `ok=false` 结构化结果并
///   debugPrint（调用方据此**不标已读**、回退既有 Dart 解析路径，绝不抛出）。
class OhosPlatformBridge {
  static const MethodChannel _channel = MethodChannel('selfmusic/platform');

  OhosPlatformBridge._();

  /// 系统目录选择能力（FOLDER）是否可用；同进程内缓存。
  static bool? _folderSelectionSupported;

  /// 查询系统目录选择能力：鸿蒙 6 手机/平板为 false，鸿蒙 7/PC 为 true。
  ///
  /// 桥未装配/调用异常按 false 处理（走文件多选降级，绝不让系统
  /// FilePicker 弹「功能未开放」）。
  static Future<bool> supportsFolderSelection() async {
    final cached = _folderSelectionSupported;
    if (cached != null) return cached;
    try {
      final supported =
          await _channel.invokeMethod<bool>('supportsFolderSelection') ?? false;
      _folderSelectionSupported = supported;
      return supported;
    } on PlatformException catch (e) {
      debugPrint('[ohos] supportsFolderSelection 失败（按不支持处理）: $e');
      _folderSelectionSupported = false;
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] supportsFolderSelection 桥未装配: $e');
      _folderSelectionSupported = false;
      return false;
    }
  }

  /// 仅供单测：清空能力/授权缓存（静态状态跨用例共享）。
  @visibleForTesting
  static void debugResetCapabilityCache() {
    _folderSelectionSupported = null;
    _activatedUris.clear();
    _activatedDirs.clear();
    _activatedWriteDirs.clear();
    _activatingDirs.clear();
  }

  /// 目录选择结果：[uri] 为授权目录 URI（`file://docs/...` 形态，直接
  /// 存入源配置 path 字段）；[path] 为可写沙箱路径；[persisted] 为持久化
  /// 是否成功（false 时本次会话临时授权仍可用，重启后需重选）。
  static Future<OhosPickedDirectory?> pickDirectory({bool write = false}) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'pickDirectory', <String, Object?>{if (write) 'write': true});
      if (raw == null) return null; // 用户取消。
      final uri = raw['uri'] as String?;
      if (uri == null || uri.isEmpty) return null;
      return OhosPickedDirectory(
          uri: uri, path: raw['path'] as String?, persisted: raw['persisted'] == true);
    } on PlatformException catch (e) {
      debugPrint('[ohos] pickDirectory 失败: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] pickDirectory 桥未装配: $e');
      return null;
    }
  }

  /// 多选音频文件（鸿蒙 6 手机/平板无 FOLDER 能力时的降级入口）。
  ///
  /// 使用 DocumentViewPicker FILE 模式（非 AudioViewPicker）：document URI
  /// 在 API 20 即可持久化，媒体 URI 要到 API 22。返回 null 表示用户取消；
  /// 真实失败向上抛 [PlatformException]/[MissingPluginException]，由调用方
  /// toast——避免把失败误判成取消。
  static Future<List<OhosPickedFile>?> pickAudioFiles() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('pickAudioFiles');
    if (raw == null) return null;
    final out = <OhosPickedFile>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final uri = e['uri'] as String?;
      if (uri == null || uri.isEmpty) continue;
      out.add(OhosPickedFile(
        uri: uri,
        name: (e['name'] as String?) ?? '',
        size: _asInt(e['size']),
        mtime: _asInt(e['mtime']),
        persisted: e['persisted'] == true,
        readable: e['readable'] == true,
      ));
    }
    return out;
  }

  /// 拉起系统文件保存界面，把 [sourcePath]（沙箱临时日志）复制到用户选择
  /// 的位置，返回保存后的 URI（`file://docs/...`）；用户取消返回 null。
  ///
  /// 背景（2026-10-20 日志导出修复）：`file_selector_ohos` 0.5.0 未实现
  /// `getDirectoryPath`（pigeon 通道没注册处理器），鸿蒙端调用必抛
  /// `PlatformException(channel-error, Unable to establish connection on
  /// channel.)`；日志导出改走本桥的 DocumentViewPicker 保存模式。
  ///
  /// 与 [pickDirectory] 不同，真实失败不吞：向上抛 [PlatformException]，
  /// 由调用方 toast「日志导出失败」——静默返回 null 会被误判为用户取消。
  static Future<String?> saveFile({
    required String suggestedName,
    required String sourcePath,
  }) async {
    final saved =
        await _channel.invokeMethod<String>('saveFile', <String, Object?>{
      'suggestedName': suggestedName,
      'sourcePath': sourcePath,
    });
    return (saved == null || saved.isEmpty) ? null : saved;
  }

  /// 重启后激活已持久化的目录授权；失败（授权被撤销/目录删除）抛
  /// [PlatformException]，由调用方转译为引导文案。[write] 为 true 时申请
  /// 读写授权，同时覆盖后续读取。
  static Future<void> activateDirectory(String uri, {bool write = false}) async {
    await _channel.invokeMethod<void>('activateDirectory', <String, Object?>{
      'uri': uri,
      if (write) 'write': true,
    });
  }

  /// 进程内已成功激活的目录 URI（成功才缓存；失败允许下次重试）。
  static final Set<String> _activatedDirs = <String>{};

  /// 进程内已成功激活读写权限的目录 URI。
  static final Set<String> _activatedWriteDirs = <String>{};

  /// 进程内已成功激活的文件 URI（文件级本地源用）。
  static final Set<String> _activatedUris = <String>{};

  /// 同 URI/模式激活中的单飞 Future（并发访问只发一次桥调用）。
  static final Map<String, Future<bool>> _activatingDirs =
      <String, Future<bool>>{};

  /// 幂等激活已持久化的目录授权（鸿蒙每次进程启动后都需激活一次）。
  ///
  /// - 同 URI/模式单飞：并发/重复调用共享同一个 Future，成功后进程内缓存；
  /// - 写授权成功同时视为读授权成功（[write] 模式本身包含读）；
  /// - 失败只 `debugPrint` 并返回 `false`，不向上抛——调用方按「本次访问
  ///   失败」处理（会话内临时授权仍可能可用，回退路径继续尝试）；
  /// - 失败不缓存，下次访问会重试（用户重新选择目录后无需重启进程）。
  static Future<bool> ensureDirectoryActivated(String uri,
      {bool write = false}) {
    if (uri.isEmpty) return Future<bool>.value(false);
    if (write) {
      if (_activatedWriteDirs.contains(uri)) return Future<bool>.value(true);
    } else if (_activatedDirs.contains(uri)) {
      return Future<bool>.value(true);
    }
    final key = write ? 'w:$uri' : 'r:$uri';
    final inflight = _activatingDirs[key];
    if (inflight != null) return inflight;
    final future = _activateDirectoryOnce(uri, write: write);
    _activatingDirs[key] = future;
    future.whenComplete(() {
      if (identical(_activatingDirs[key], future)) _activatingDirs.remove(key);
    });
    return future;
  }

  static Future<bool> _activateDirectoryOnce(String uri,
      {required bool write}) async {
    try {
      await activateDirectory(uri, write: write);
      _activatedDirs.add(uri);
      if (write) _activatedWriteDirs.add(uri);
      debugPrint('[ohos] 目录授权已激活（write=$write）: $uri');
      return true;
    } on PlatformException catch (e) {
      debugPrint('[ohos] 目录授权激活失败（下次访问重试）: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] 目录授权激活桥未装配: $e');
      return false;
    } catch (e) {
      // 任何非平台异常也不阻断播放链路；不缓存，下次访问重试。
      debugPrint('[ohos] 目录授权激活异常（下次访问重试）: $e');
      return false;
    }
  }

  /// 批量幂等激活文件 URI 授权，返回与入参同序的可用状态。
  ///
  /// 已缓存的 URI 直接 true；其余按 100 个一批调用桥，单批失败时该批
  /// 按 false 返回但不抛出（扫描据此标记文件不可读，待用户重新选择）。
  static Future<List<bool>> ensureUrisActivated(List<String> uris) async {
    final out = List<bool>.filled(uris.length, false);
    if (uris.isEmpty) return out;
    final pending = <int>[];
    for (var i = 0; i < uris.length; i++) {
      final uri = uris[i];
      if (uri.isEmpty) continue;
      if (_activatedUris.contains(uri)) {
        out[i] = true;
      } else {
        pending.add(i);
      }
    }
    const chunk = 100;
    for (var start = 0; start < pending.length; start += chunk) {
      final end =
          start + chunk > pending.length ? pending.length : start + chunk;
      final batch = pending.sublist(start, end);
      try {
        final flags = await activateUris([for (final i in batch) uris[i]]);
        for (var j = 0; j < batch.length; j++) {
          final ok = j < flags.length && flags[j];
          final index = batch[j];
          out[index] = ok;
          if (ok) _activatedUris.add(uris[index]);
        }
      } catch (e) {
        debugPrint('[ohos] 文件授权激活失败（本批按不可用处理）: $e');
      }
    }
    return out;
  }

  /// 批量激活已持久化的文件 URI（按 100 个一批）；失败向上抛。
  static Future<List<bool>> activateUris(List<String> uris) async {
    if (uris.isEmpty) return const [];
    final out = List<bool>.filled(uris.length, false);
    const chunk = 100;
    for (var start = 0; start < uris.length; start += chunk) {
      final end = start + chunk > uris.length ? uris.length : start + chunk;
      final raw = await _channel.invokeMethod<List<dynamic>>(
          'activateUris', <String, Object?>{'uris': uris.sublist(start, end)});
      final flags = raw ?? const <dynamic>[];
      for (var j = 0; j < end - start; j++) {
        out[start + j] = j < flags.length && flags[j] == true;
      }
    }
    return out;
  }

  /// 批量 stat 文件 URI（扫描 diff 用）；失败向上抛。
  static Future<List<OhosFileStat>> statFileUris(List<String> uris) async {
    if (uris.isEmpty) return const [];
    final raw = await _channel.invokeMethod<List<dynamic>>(
        'statFileUris', <String, Object?>{'uris': uris});
    final out = <OhosFileStat>[];
    for (final e in raw ?? const <dynamic>[]) {
      if (e is! Map) continue;
      final uri = e['uri'] as String?;
      if (uri == null || uri.isEmpty) continue;
      out.add(OhosFileStat(
        uri: uri,
        ok: e['ok'] == true,
        size: _asInt(e['size']),
        mtime: _asInt(e['mtime']),
        code: (e['code'] as String?) ?? '',
      ));
    }
    return out;
  }

  /// 文件 URI 范围读（单次上限 2 MiB，由 ArkTS 侧防御）；失败向上抛。
  static Future<Uint8List> readFileUriRange(
      String uri, int offset, int length) async {
    final data = await _channel
        .invokeMethod<Uint8List>('readFileUriRange', <String, Object?>{
      'uri': uri,
      'offset': offset,
      'length': length,
    });
    return data ?? Uint8List(0);
  }

  /// 解析文件 URI 的沙箱真路径；失败时先激活授权再重试一次。
  static Future<String?> resolveFileUriWithActivation(String uri) async {
    final first = await _resolveFileUri(uri, logFailure: false);
    if (first != null) return first;
    final flags = await ensureUrisActivated([uri]);
    if (flags.isEmpty || !flags.first) return null;
    return _resolveFileUri(uri, logFailure: true);
  }

  static Future<String?> _resolveFileUri(String uri,
      {required bool logFailure}) async {
    try {
      return await _channel.invokeMethod<String>(
          'resolveFileUri', <String, Object?>{'uri': uri});
    } on PlatformException catch (e) {
      if (logFailure) debugPrint('[ohos] resolveFileUri 失败（回退字节流分支）: $e');
      return null;
    } on MissingPluginException catch (e) {
      if (logFailure) debugPrint('[ohos] resolveFileUri 桥未装配: $e');
      return null;
    }
  }

  /// 解析文件沙箱真路径，失败时先幂等激活目录授权再重试一次。
  ///
  /// 重启后首次访问的持久化授权尚未激活，[resolvePath] 会返回 `null`；
  /// 这里统一兜住「激活 → 重试」，避免播放/补读各自实现。
  static Future<String?> resolvePathWithActivation(
      String uri, String rel) async {
    // 首次失败不打印「回退字节流」——冷启动未激活属预期，激活后会重试。
    final first = await _resolvePath(uri, rel, logFailure: false);
    if (first != null) return first;
    if (!await ensureDirectoryActivated(uri)) return null;
    return _resolvePath(uri, rel, logFailure: true);
  }

  /// 仅供单测：清空激活缓存（静态状态跨用例共享）。
  @visibleForTesting
  static void debugResetDirectoryActivation() {
    _activatedDirs.clear();
    _activatedWriteDirs.clear();
    _activatingDirs.clear();
  }

  /// 递归枚举授权目录（快照：rel/size/mtime），供扫描 diff 使用。
  static Future<List<OhosDirEntry>> listDirectory(String uri) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
        'listDirectory', <String, Object?>{'uri': uri});
    final out = <OhosDirEntry>[];
    for (final e in raw ?? const <dynamic>[]) {
      if (e is! Map) continue;
      final rel = e['rel'] as String?;
      final size = e['size'] as int?;
      final mtime = e['mtime'] as int?;
      if (rel == null || size == null || mtime == null) continue;
      out.add(OhosDirEntry(rel: rel, size: size, mtime: mtime));
    }
    return out;
  }

  /// 范围读授权目录内文件（单次上限 2 MiB，由 ArkTS 侧防御）。
  ///
  /// [rel] 为库内 song ref（无头相对路径）；ArkTS 侧按 `uri + rel` 拼接且
  /// fs.listFile 返回的相对路径以 `/` 开头，这里补回头部斜杠（幂等）。
  static Future<Uint8List> readRange(
      String uri, String rel, int offset, int length) async {
    final fullRel = rel.startsWith('/') ? rel : '/$rel';
    final data = await _channel.invokeMethod<Uint8List>(
        'readRange', <String, Object?>{
      'uri': uri,
      'rel': fullRel,
      'offset': offset,
      'length': length
    });
    return data ?? Uint8List(0);
  }

  /// 解析授权目录内文件的沙箱真路径（openSync(uri).path），供本地源
  /// [MusicSource.cachedFilePath] 的 ohos 分支使用：播放走 setFilePath
  /// 直连（mdk 原生 file://），绕开 just_audio 本地代理。
  ///
  /// 2026-10-07 播放管线修复：此前 ohos 一律回 null 走字节流分支
  /// （DirectAudioSource → just_audio 本地代理），真机取证发现代理对
  /// 死锁后 socket 事件通知以 ~305µs 周期空转（~2.9k HandleMessage/s，
  /// ~1.5 核 CPU），启动断点恢复即触发。失败/桥未装配返回 null，调用方
  /// 回退字节流分支（行为同修复前）。
  ///
  /// 业务层优先用 [resolvePathWithActivation]：冷启动后持久化授权未激活时
  /// 会自动激活并重试一次，避免直接落到字节流分支后 readRange 同样失败。
  static Future<String?> resolvePath(String uri, String rel) =>
      _resolvePath(uri, rel, logFailure: true);

  static Future<String?> _resolvePath(String uri, String rel,
      {required bool logFailure}) async {
    final fullRel = rel.startsWith('/') ? rel : '/$rel';
    try {
      return await _channel.invokeMethod<String>(
          'resolvePath', <String, Object?>{'uri': uri, 'rel': fullRel});
    } on PlatformException catch (e) {
      if (logFailure) debugPrint('[ohos] resolvePath 失败（回退字节流分支）: $e');
      return null;
    } on MissingPluginException catch (e) {
      if (logFailure) debugPrint('[ohos] resolvePath 桥未装配: $e');
      return null;
    }
  }

  /// 窗口常亮开关（无需权限，仅前台生效）。失败仅记日志不中断——常亮
  /// 属体验增强，不应影响播放。
  static Future<void> keepScreenOn(bool enable) async {
    try {
      await _channel.invokeMethod<void>(
          'keepScreenOn', <String, Object?>{'enable': enable});
    } on PlatformException catch (e) {
      debugPrint('[ohos] keepScreenOn($enable) 失败: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] keepScreenOn 桥未装配: $e');
    }
  }

  /// 蓝牙权限三段式申请（checkAccessToken 短路 → 首弹窗 → 设置弹框），
  /// 结果只表达「当前是否可用」；任何阶段异常均返回 false。
  static Future<bool> requestBluetoothPermission() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('requestBluetoothPermission');
      return raw != null && raw['granted'] == true;
    } on PlatformException catch (e) {
      debugPrint('[ohos] requestBluetoothPermission 失败: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] requestBluetoothPermission 桥未装配: $e');
      return false;
    }
  }

  /// 当前是否持有 ACCESS_BLUETOOTH；异常按 false（门控据此判定未连接）。
  static Future<bool> hasBluetoothPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasBluetoothPermission') ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[ohos] hasBluetoothPermission 失败: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] hasBluetoothPermission 桥未装配: $e');
      return false;
    }
  }

  /// 已配对蓝牙设备（name 空回退 address）；权限缺失/蓝牙关闭/能力不
  /// 支持一律降级空数组（对齐 Android 静默降级 + 诊断日志）。
  static Future<List<(String, String)>> listBondedDevices() async {
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('listBondedDevices');
      final out = <(String, String)>[];
      for (final e in raw ?? const <dynamic>[]) {
        if (e is! Map) continue;
        final name = e['name'] as String?;
        final address = e['address'] as String?;
        if (name == null || address == null) continue;
        out.add((name, address));
      }
      return out;
    } on PlatformException catch (e) {
      debugPrint('[ohos] listBondedDevices 失败（按空处理）: $e');
      return const [];
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] listBondedDevices 桥未装配: $e');
      return const [];
    }
  }

  /// 当前已连接蓝牙音频设备地址集合；异常降级空集合（门控按未连接判定）。
  static Future<Set<String>> connectedDevices() async {
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('connectedDevices');
      return {for (final e in raw ?? const <dynamic>[]) '$e'};
    } on PlatformException catch (e) {
      debugPrint('[ohos] connectedDevices 失败（按空处理）: $e');
      return const {};
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] connectedDevices 桥未装配: $e');
      return const {};
    }
  }

  /// 封面缩略图原生生成（第 10 个通道方法，ohos-thumb-native-decode
  /// feature）：解码 → EXIF 方向烘焙 → 最长边 [maxEdge] 降采样 → JPEG
  /// [quality] 重编码 → `<thumbPath>.tmp` 写盘后 rename——全链在 ArkTS 侧
  /// @ohos.multimedia.image 系统原生线程完成，缩略图字节不过通道。
  ///
  /// [srcPath] 为封面原图沙箱路径，[thumbPath] 为目标缩略图路径（沿用
  /// `cover_thumb.dart` 的 `<md5>.thumb.jpg` 约定）；[maxEdge]/[quality]
  /// 缺省 768/82（与 kCoverThumbMaxEdge / kCoverThumbQuality 对齐）。
  ///
  /// **线程隔离（ohos-thumb-taskpool feature，2026-10-08）**：原生侧不再在 UI
  /// 主线程内联执行管线，而是委托 `ThumbDispatcher` 到任务池/Worker 独立线程
  /// （契约见 spec/ohos-thumb-taskpool plan.md R-1/R-3）。通道方法名/参数不变。
  ///
  /// **返回解析兼容（R-8 / T004）**：保持 bool 成功语义，同时兼容原生侧新增的
  /// 结构化返回 `{ok, costMs, degraded}`；[makeCoverThumbDetailed] 暴露结构化
  /// 细节（供埋点）而 [makeCoverThumb] 仅取 `ok`（既有调用方零改动）。
  ///
  /// 失败兜底（plan.md R-5）：[PlatformException] / [MissingPluginException] /
  /// [TimeoutException] 与 false/ok=false 返回一律 debugPrint 诊断日志后返回
  /// 失败，**绝不抛出、绝不回退内联 Dart 编码**（根 isolate 上等于把数百 ms UI 块
  /// 请回来）——调用方按「缩略图是纯优化」静默回原图显示。15s 超时上限覆盖
  /// 原生解码大图的合法秒级耗时，超时后本轮放弃、下次触发重试；[timeout]
  /// 仅供测试注入。
  static Future<bool> makeCoverThumb(String srcPath, String thumbPath,
      {int maxEdge = 768,
      int quality = 82,
      Duration timeout = const Duration(seconds: 15)}) async {
    final r = await makeCoverThumbDetailed(srcPath, thumbPath,
        maxEdge: maxEdge, quality: quality, timeout: timeout);
    return r.ok;
  }

  /// [makeCoverThumb] 的结构化版本：解析 `{ok,costMs,degraded}`（旧 bool 形态
  /// 同样兼容），供生成链路埋点（`ThumbGenStats`）取单张耗时与降级标记。
  static Future<OhosThumbResult> makeCoverThumbDetailed(
      String srcPath, String thumbPath,
      {int maxEdge = 768,
      int quality = 82,
      Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('makeCoverThumb', <String, Object?>{
        'srcPath': srcPath,
        'thumbPath': thumbPath,
        'maxEdge': maxEdge,
        'quality': quality
      }).timeout(timeout);
      return OhosThumbResult.fromChannel(raw);
    } on TimeoutException catch (e) {
      debugPrint('[ohos] makeCoverThumb 超时（放弃本轮，下次触发重试）: $e');
      return const OhosThumbResult(ok: false, timeout: true);
    } on PlatformException catch (e) {
      debugPrint('[ohos] makeCoverThumb 失败: $e');
      return const OhosThumbResult(ok: false);
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] makeCoverThumb 桥未装配: $e');
      return const OhosThumbResult(ok: false);
    }
  }

  /// 音频元数据原生解析（第 11 个通道方法，ohos-meta-enrich-native feature；
  /// 契约见 `spec/ohos-meta-enrich-native/plan.md` R-1）。
  ///
  /// 标签解析与封面提取在 ArkTS 侧 `@Concurrent` 任务池执行
  /// （`AudioMetaTask.ets` → `AudioMetaPipeline.ets` 的 `AVMetadataExtractor`），
  /// Dart 只接收结构化结果并落库——主线程不再承担纯 Dart 解析重活（FR-002/003）。
  ///
  /// [path] 为音频沙箱真路径（`resolvePath` 结果）；[coverPath] 为封面落盘目标
  /// （沿用 `persistCover` 的 `covers/<md5(ref)>.jpg` 口径，由 Dart 计算后传入——
  /// 原生写 `<coverPath>.tmp` 后 rename 原子落盘并从结果回传）。
  ///
  /// 失败兜底：任何失败（超时/桥未装配/原生 ok=false）返回 `ok=false` 结构化
  /// 结果，**绝不抛出**；调用方据 `ok` 决定是否标已读（失败不标）。[timeout]
  /// 覆盖原生解析 + 大封面落盘的合法秒级耗时，仅供测试注入。
  static Future<OhosAudioMetaResult> extractAudioMeta(
    String path, {
    String? coverPath,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'extractAudioMeta', <String, Object?>{
        'path': path,
        if (coverPath != null && coverPath.isNotEmpty) 'coverPath': coverPath,
      }).timeout(timeout);
      return OhosAudioMetaResult.fromChannel(raw);
    } on TimeoutException catch (e) {
      debugPrint('[ohos] extractAudioMeta 超时（本轮放弃，下次重试）: $e');
      return OhosAudioMetaResult.failure('timeout');
    } on PlatformException catch (e) {
      debugPrint('[ohos] extractAudioMeta 失败: $e');
      return OhosAudioMetaResult.failure(e.message ?? 'platform');
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] extractAudioMeta 桥未装配: $e');
      return OhosAudioMetaResult.failure('missing-plugin');
    }
  }
}

/// `makeCoverThumb` 的结构化结果：成功语义 + 可选原生自报耗时/降级标记。
class OhosThumbResult {
  /// 是否成功落盘（唯一权威成功语义，与既有 bool 返回一致）。
  final bool ok;

  /// 原生侧自报单张耗时（ms，旧 bool 形态/异常时为 null）。
  final int? costMs;

  /// 降级标记（如 `worker`；空/旧形态时为 null）。
  final String? degraded;

  /// 是否因超时结束（埋点区分超时与失败用）。
  final bool timeout;

  const OhosThumbResult(
      {required this.ok, this.costMs, this.degraded, this.timeout = false});

  /// 兼容解析：旧 bool 形态（true/false）或新结构化 `{ok,costMs,degraded}`，
  /// 其它形态（null/未知）一律按失败处理（R-8）。
  factory OhosThumbResult.fromChannel(Object? raw) {
    if (raw is bool) return OhosThumbResult(ok: raw);
    if (raw is Map) {
      final ok = raw['ok'];
      final cost = raw['costMs'];
      final deg = raw['degraded'];
      return OhosThumbResult(
        ok: ok == true,
        costMs: cost is int ? cost : (cost is num ? cost.toInt() : null),
        degraded: (deg is String && deg.isNotEmpty) ? deg : null,
      );
    }
    return const OhosThumbResult(ok: false);
  }
}

/// pickDirectory 结果：授权目录 URI + 沙箱路径 + 是否已持久化。
class OhosPickedDirectory {
  final String uri;
  final String? path;
  final bool persisted;
  const OhosPickedDirectory(
      {required this.uri, this.path, required this.persisted});
}

/// pickAudioFiles 单项：文件 URI + 展示名 + stat + 授权状态。
class OhosPickedFile {
  final String uri;
  final String name;
  final int size;
  final int mtime;
  final bool persisted;
  final bool readable;
  const OhosPickedFile({
    required this.uri,
    required this.name,
    required this.size,
    required this.mtime,
    required this.persisted,
    required this.readable,
  });
}

/// statFileUris 单项：成功状态 + 大小/mtime + 失败错误码。
class OhosFileStat {
  final String uri;
  final bool ok;
  final int size;
  final int mtime;
  final String code;
  const OhosFileStat({
    required this.uri,
    required this.ok,
    required this.size,
    required this.mtime,
    required this.code,
  });
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

/// listDirectory 单项：目录内相对路径（`/` 开头）+ 文件大小 + mtime（秒）。
class OhosDirEntry {
  final String rel;
  final int size;
  final int mtime;
  const OhosDirEntry(
      {required this.rel, required this.size, required this.mtime});
}

/// `extractAudioMeta` 的结构化结果（原生标签 + 封面落盘路径）。
///
/// 容错解析：任何非 Map / 缺字段一律按缺省（空串 / 0）处理；[ok] 仅当原生明确回
/// `true` 时成立（与「失败不标已读」语义对齐）。
class OhosAudioMetaResult {
  /// 是否解析成功（唯一权威成功语义：true 才允许标已读）。
  final bool ok;

  /// 标题（''=缺失）。
  final String title;

  /// 歌手（''=缺失）。
  final String artist;

  /// 专辑（''=缺失）。
  final String album;

  /// 专辑歌手（''=缺失）。
  final String albumArtist;

  /// 流派（''=缺失）。
  final String genre;

  /// 时长（毫秒，原生自报；0=未知）。
  final int durationMs;

  /// 音轨号（0=未知；原生 `AVMetadata` 当前不提供，恒 0）。
  final int trackNo;

  /// 年份（0=未知）。
  final int year;

  /// 封面落盘路径（原生已写盘；''=无内嵌封面）。
  final String coverPath;

  /// 内嵌歌词（原生当前不提供，字段预留；''=缺失）。
  final String lyric;

  /// 本首原生耗时（ms）。
  final int costMs;

  /// 失败原因摘要（''=无）。
  final String error;

  const OhosAudioMetaResult({
    required this.ok,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.genre = '',
    this.durationMs = 0,
    this.trackNo = 0,
    this.year = 0,
    this.coverPath = '',
    this.lyric = '',
    this.costMs = 0,
    this.error = '',
  });

  /// 构造失败结果（附简短原因）。
  factory OhosAudioMetaResult.failure(String error) =>
      OhosAudioMetaResult(ok: false, error: error);

  /// 容错解析：非 Map 一律按失败处理；字段缺失/类型不符按缺省。
  factory OhosAudioMetaResult.fromChannel(Object? raw) {
    if (raw is! Map) return OhosAudioMetaResult.failure('bad-result');
    return OhosAudioMetaResult(
      ok: raw['ok'] == true,
      title: _str(raw['title']),
      artist: _str(raw['artist']),
      album: _str(raw['album']),
      albumArtist: _str(raw['albumArtist']),
      genre: _str(raw['genre']),
      durationMs: _int(raw['durationMs']),
      trackNo: _int(raw['trackNo']),
      year: _int(raw['year']),
      coverPath: _str(raw['coverPath']),
      lyric: _str(raw['lyric']),
      costMs: _int(raw['costMs']),
      error: _str(raw['error']),
    );
  }

  /// 时长（秒，四舍五入；未知/异常返回 null）——与 `enrichSong(duration:)` 口径一致。
  ///
  /// **单位假设**：原生 `AVMetadata.duration` 官方文档未标注单位，此处按**毫秒**
  /// 处理并换算为秒（见 spec 残留风险；若真机核对为秒需改此口径）。
  int? get durationSec {
    if (durationMs <= 0) return null;
    final s = (durationMs / 1000).round();
    return s > 0 ? s : null;
  }

  /// 归一化文本字段：空串 → null。供 `enrichSong` 的 `COALESCE(NULLIF(...))` 语义
  /// 保持库中既有值（缺失字段留空而非劣化）。
  String? get titleOrNull => title.isEmpty ? null : title;
  String? get artistOrNull => artist.isEmpty ? null : artist;
  String? get albumOrNull => album.isEmpty ? null : album;
  String? get albumArtistOrNull => albumArtist.isEmpty ? null : albumArtist;
  String? get genreOrNull => genre.isEmpty ? null : genre;
  int? get trackNoOrNull => trackNo > 0 ? trackNo : null;
  int? get yearOrNull => year > 0 ? year : null;
  String? get coverPathOrNull => coverPath.isEmpty ? null : coverPath;
  String? get lyricOrNull => lyric.trim().isEmpty ? null : lyric;

  static String _str(Object? v) => v is String ? v : '';

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }
}

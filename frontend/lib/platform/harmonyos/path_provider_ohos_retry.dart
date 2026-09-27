import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// flutter_ohos 引擎启动竞态的自救包装：给所有 path_provider 平台通道调用
/// 加「超时 + 重发」。
///
/// ## 根因（真机取证，2026-09）
///
/// flutter_ohos（fork `62357a9`，HAR `1.0.0-4cbeea6a36f1`）在启动早期存在
/// 竞态窗口：XComponent Surface 创建风暴（NotifyCreate / Rasterizer::Setup /
/// frame_gate）后约 130ms 内发出的平台消息，其**响应回调路由在 libflutter.so
/// 内部丢失**——ArkTS 插件侧 handler 正常执行、`reply.reply()` 正常发出，
/// 但 `nativeInvokePlatformMessageResponseCallback` 查找响应 ID 失败且无日志，
/// Dart 侧 `await` 永远等不到回复。
///
/// 表现为启动白屏：`main()` 卡死在 `ServerSettings.load()` →
/// `getApplicationSupportDirectory()`（VM service 取栈为证：isolate 空闲、
/// 无异常、无后续消息，runApp 从未执行）。竞态是纯时序问题——窗口外启动
/// 完全正常，故**超时后重发即可自愈**。
///
/// 根修在引擎（建议携证据链上报 openharmony-sig/flutter_ohos）；本类是
/// 应用层兜底，根修落地后可移除。
///
/// ## 行为
///
/// - 单次调用 1 秒超时（正常响应为毫秒级，1 秒无响应即判定回复被吞）；
///   最多重发 5 次。竞态窗口约 130ms，第一次重发（1 秒后）必然已在窗口外。
/// - 路径查询幂等无副作用，迟到的旧回复无人消费，重发安全。
/// - 仅 [TimeoutException] 触发重试；其它异常（如 ohos 上 `getLibraryPath`
///   的 `UnsupportedError`）原样透传，保持插件既有语义。
/// - 5 次全部超时（概率≈0，仅引擎彻底失常时）：单路径方法回退到引擎注入的
///   应用文件沙盒 [fallbackPath]（见引擎 init 日志 `appStoragePath`），
///   **保 main() 必然走完——白屏比目录语义不精确更糟**；列表方法（外置存储
///   系列，启动链不使用）回退 null。
class OhosRetryingPathProvider extends PathProviderPlatform {
  OhosRetryingPathProvider(this._delegate);

  /// 被包装的原实现（ohos 上即引擎注册的 PathProviderOhos）。
  final PathProviderPlatform _delegate;

  /// 单次等待平台回复的上限；正常响应毫秒级，超时即按「回复被竞态吞掉」处理。
  static const Duration _timeout = Duration(seconds: 1);

  /// 最多尝试次数（1 次原始 + 4 次重发）。
  static const int _maxAttempts = 5;

  /// 引擎失常时的保命路径：应用文件沙盒（进程视角固定路径，debug/release 一致）。
  static const String fallbackPath = '/data/storage/el2/base/haps/entry/files';

  Future<T?> _withRetry<T>(String name, Future<T?> Function() op) async {
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        return await op().timeout(_timeout);
      } on TimeoutException {
        debugPrint('[ohos] path_provider.$name 响应超时'
            '（引擎启动竞态），重试 $attempt/$_maxAttempts');
      }
    }
    debugPrint('[ohos] path_provider.$name 重试 $_maxAttempts 次仍无响应，'
        '回退沙盒路径 $fallbackPath');
    return null;
  }

  /// 单路径方法：全超时回退 [fallbackPath]（启动链依赖 documents/support）。
  Future<String?> _withRetryOrFallback(
      String name, Future<String?> Function() op) async {
    final result = await _withRetry<String>(name, op);
    return result ?? fallbackPath;
  }

  @override
  Future<String?> getTemporaryPath() =>
      _withRetryOrFallback('getTemporaryPath', _delegate.getTemporaryPath);

  @override
  Future<String?> getApplicationSupportPath() => _withRetryOrFallback(
      'getApplicationSupportPath', _delegate.getApplicationSupportPath);

  @override
  Future<String?> getApplicationDocumentsPath() => _withRetryOrFallback(
      'getApplicationDocumentsPath', _delegate.getApplicationDocumentsPath);

  @override
  Future<String?> getApplicationCachePath() => _withRetryOrFallback(
      'getApplicationCachePath', _delegate.getApplicationCachePath);

  // iOS/macOS 专属与 ohos 不支持项：委托保持原异常语义，不重试包装
  // （UnsupportedError 会直接透传）。

  @override
  Future<String?> getLibraryPath() => _delegate.getLibraryPath();

  @override
  Future<String?> getExternalStoragePath() =>
      _delegate.getExternalStoragePath();

  @override
  Future<String?> getDownloadsPath() => _delegate.getDownloadsPath();

  @override
  Future<List<String>?> getExternalCachePaths() =>
      _withRetry('getExternalCachePaths', _delegate.getExternalCachePaths);

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _withRetry('getExternalStoragePaths',
          () => _delegate.getExternalStoragePaths(type: type));
}

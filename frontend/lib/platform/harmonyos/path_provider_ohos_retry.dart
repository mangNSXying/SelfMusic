import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// flutter_ohos 引擎异常的保险层：给所有 path_provider 平台通道调用加
/// 「poke 驱动重发 + 超时重发 + 兜底路径」。
///
/// ## 定位史（真机 verify-1~4，2026-09-28 定稿）
///
/// 启动白屏真凶最终定位为 **flutter_secure_storage 9.2.4 包前端在 ohos
/// 上抛 `UnsupportedError`**（平台分支六选一无 ohos），沿 main() 未捕获
/// 静默死亡——取证与修复见 secure_storage_ohos.dart / DEVELOPER.md。此前
/// 三轮引擎侧结论经 verify-4（VM service 活体取证）全部翻案：
/// - **回复投递正常**（推翻 verify-2）：support 调用完成后 `_pendingCalls`
///   为空 = 回复已送达、await 已恢复，main() 死于更下游的 secure storage；
/// - **包装从未被覆盖**（推翻 verify-3）：安装日志 delegate=PathProviderOhos
///   证明引擎注册器在 main() 之前已执行完毕，不存在覆盖窗口；
/// - **Timer 子系统死亡未证实**：旧「delay 未触发」的观察与「main 早已
///   死亡、后续代码根本没跑」无法区分，不作为结论使用。
///
/// verify-4 唯一坐实的引擎疑点：**启动期未捕获异常完全静默**（hilog 零
/// 输出，无任何 Dart 错误痕迹），排障成本极高。
///
/// ## 保留理由（保险而非修复）
///
/// fork 引擎（`62357a9`，HAR `1.0.0-4cbeea6a36f1`）质量存疑：若未来版本
/// 真出现「单条回复丢失」「Timer 不触发」或「注册器覆盖 instance」，本
/// 包装 + ArkTS 看门狗每秒 poke（EntryAbility.ets → ohos_bootstrap →
/// [nudgeAllPending]）是实测过的恢复手段：对在途未回的调用**重新发起**，
/// 新回复产生于健康时段（poke 自身收发回执全程毫秒级）。Timer 超时仅作
/// 辅助触发源（Timer 可用时才生效，不依赖任何未证实结论）。
///
/// ## 行为
///
/// - 最多尝试 12 次（Timer 触发与 poke 触发共享预算）；路径查询幂等无
///   副作用，重发安全，重复/迟到回复先到先得、后到忽略。
/// - 非超时异常（如 ohos 上 `getLibraryPath` 的 `UnsupportedError`）
///   原样透传，保持插件既有语义。
/// - 全部尝试失败（引擎彻底失常，概率≈0）：单路径方法回退引擎注入的
///   应用文件沙盒 [fallbackPath]（见引擎 init 日志 `appStoragePath`），
///   **保 main() 必然走完——白屏比目录语义不精确更糟**；列表方法（外置
///   存储系列，启动链不使用）回退 null。
///
/// 多点惰性自断言（[ensureOhosPathWrapper]）：setupOhos / 每次看门狗
/// poke / 首次路径调用现场各断言一次包装在位，防未来引擎行为变化；
/// 白屏根因修复稳定数个版本后，本类与看门狗可整体移除。
class OhosRetryingPathProvider extends PathProviderPlatform {
  OhosRetryingPathProvider(this._delegate) {
    _allWrappers.add(this);
  }

  /// 被包装的原实现（ohos 上即引擎注册的 PathProviderOhos）。
  final PathProviderPlatform _delegate;

  /// 历史上创建的全部包装实例：注册器可能中途覆盖 instance，旧实例里
  /// 可能仍有在途调用——poke 重发对全部实例生效（[nudgeAllPending]），
  /// 不丢任何在途状态。
  static final List<OhosRetryingPathProvider> _allWrappers =
      <OhosRetryingPathProvider>[];

  /// 单次等待平台回复的上限；正常响应毫秒级。
  /// 仅在本 isolate 的 Timer 可用时生效（Timer 可靠性未证实，见头注释）。
  static const Duration _timeout = Duration(seconds: 1);

  /// 最多尝试次数（1 次原始 + 11 次重发；Timer 触发与 poke 触发共享）。
  static const int _maxAttempts = 12;

  /// 引擎失常时的保命路径：应用文件沙盒（进程视角固定路径，debug/release 一致）。
  static const String fallbackPath = '/data/storage/el2/base/haps/entry/files';

  /// 在途（发出未回）的调用状态表；[nudgePending] 遍历触发重发。
  final Set<_PendingCall> _pendingCalls = <_PendingCall>{};

  /// 看门狗 poke 到达时调用（ohos_bootstrap 的 boot 通道 handler）：
  /// 对所有在途未回的路径调用触发一次重发。
  ///
  /// 重发而非干等原回复：若「单条回复丢失」真发生，重发的新回复产生于
  /// 健康时段（poke 自身收发回执毫秒级正常），可正常投递。已完成/已
  /// 失败的调用自动跳过。
  void nudgePending() {
    for (final p in _pendingCalls.toList()) {
      p.nudge();
    }
  }

  /// [nudgePending] 的全实例版本：看门狗 poke 的实际落点（ohos_bootstrap）。
  static void nudgeAllPending() {
    for (final w in _allWrappers) {
      w.nudgePending();
    }
  }

  Future<T?> _withRetry<T>(String name, Future<T?> Function() op) {
    final p = _PendingCall<T>(this, name, op);
    _pendingCalls.add(p);
    p.start();
    return p.future;
  }

  /// 单路径方法：全部尝试失败回退 [fallbackPath]（启动链依赖 documents/support）。
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

/// 惰性自断言安装重试包装：ohos 之外 no-op；instance 已是包装 no-op；
/// 否则把**当前**实例包一层装回。多点调用（setupOhos / poke / 首次路径
/// 调用现场）纯属保险——verify-4 实证当前引擎注册器在 main() 之前已
/// 执行完毕、从未覆盖包装（旧「覆盖」结论系误读，见文件头定位史）。
///
/// [reason] 仅用于安装日志定位断言点。
void ensureOhosPathWrapper(String reason) {
  if (kIsWeb || Platform.operatingSystem != 'ohos') return;
  final current = PathProviderPlatform.instance;
  if (current is OhosRetryingPathProvider) return;
  PathProviderPlatform.instance = OhosRetryingPathProvider(current);
  debugPrint(
      '[ohos] path_provider 重试包装器安装（delegate=${current.runtimeType}，'
      'reason=$reason）');
}

/// 单个在途包装调用的状态机：一次 `_fire()` = 一次尝试（发 `op()`，
/// 挂 1s 超时 Timer）；回复到达 / 超时触发 / poke 触发都会推进状态。
/// 完成即从宿主的 `_pendingCalls` 摘除，后续触发全部 no-op。
class _PendingCall<T> {
  _PendingCall(this._owner, this.name, this._op);

  final OhosRetryingPathProvider _owner;
  final String name;
  final Future<T?> Function() _op;

  final Completer<T?> _completer = Completer<T?>();
  Timer? _timer;
  int _attempts = 0;

  Future<T?> get future => _completer.future;

  void start() => _fire();

  /// 看门狗 poke 到达：在途未回则重发一次（预算内）。
  void nudge() {
    if (_completer.isCompleted) return;
    debugPrint(
        '[ohos] path_provider.$name 在途未回，poke 触发重发（第 ${_attempts + 1} 次）');
    _fire();
  }

  void _fire() {
    if (_completer.isCompleted) return;
    if (_attempts >= OhosRetryingPathProvider._maxAttempts) {
      debugPrint('[ohos] path_provider.$name 尝试 $_attempts 次仍无响应，'
          '回退兜底');
      _finish(null);
      return;
    }
    _attempts++;
    _timer?.cancel();
    // 重发不取消旧尝试：旧回复若迟到会被 isCompleted 守卫忽略。
    unawaited(_op().then((T? value) {
      _finish(value);
    }, onError: (Object e, StackTrace st) {
      // 非超时异常原样透传（保持插件语义），不再重试。
      _finishError(e, st);
    }));
    // 超时触发器：Timer 可用时兜「单条回复丢失」；Timer 不可用时静默
    // 失效，由 poke 驱动的 [nudge] 接管（Timer 可靠性未证实，不押注）。
    _timer = Timer(OhosRetryingPathProvider._timeout, () {
      if (_completer.isCompleted) return;
      debugPrint('[ohos] path_provider.$name 响应超时（引擎启动竞态），重试');
      _fire();
    });
  }

  void _finish(T? value) {
    if (_completer.isCompleted) return;
    _timer?.cancel();
    _owner._pendingCalls.remove(this);
    _completer.complete(value);
  }

  void _finishError(Object e, StackTrace st) {
    if (_completer.isCompleted) return;
    _timer?.cancel();
    _owner._pendingCalls.remove(this);
    _completer.completeError(e, st);
  }
}

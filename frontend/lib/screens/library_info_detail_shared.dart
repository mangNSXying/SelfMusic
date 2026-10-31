import 'dart:async';

import 'package:flutter/material.dart';

/// 歌曲信息详情页共用：宽窄断点、单元格样式、异步装载。
///
/// 断点复用侧边栏规则（`NavigationProviderHelper.isNarrow` 取反）：
/// 宽度 >= 900 或横屏（宽 > 高）即宽屏，其余为窄屏。
bool isWideDetail(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 900 || size.width > size.height;
}

/// 详情页全量数据的异步装载器（入场不冻帧）。
///
/// - [request] 在后台 isolate 查库（详见 `runOffThread`；测试环境内联，OHOS
///   与其它平台一样走真实子 isolate），查询期间保留 [data] 旧值不闪屏
///   （首次为 null，调用方显示 loading）；
/// - 查询在途时再次 [request] 只置脏，完成后补查一次，避免扫描期
///   高频通知把全量查询叠成一串；
/// - [onUpdate] 在数据落地（或失败）时回调，调用方 setState 驱动重建。
class DetailDataLoader<T> {
  DetailDataLoader(this._query);

  final Future<T> Function() _query;

  /// 最近一次装载成功的数据；null = 尚未装载成功。
  T? data;

  /// 首次装载失败（[data] 仍为 null）；重试成功后消除。
  bool failed = false;

  /// 数据落地/失败回调（调用方在此 setState）。
  VoidCallback? onUpdate;

  bool _inflight = false;
  bool _dirty = false;

  void request() {
    if (_inflight) {
      _dirty = true;
      return;
    }
    _inflight = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final v = await _query();
      data = v;
      failed = false;
    } catch (_) {
      failed = data == null; // 已有旧数据时静默保留，不打断浏览。
    } finally {
      _inflight = false;
      onUpdate?.call();
      if (_dirty) {
        _dirty = false;
        request();
      }
    }
  }
}


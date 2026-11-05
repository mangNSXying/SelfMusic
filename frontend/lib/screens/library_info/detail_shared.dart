import 'dart:async';

import 'package:flutter/material.dart';

/// 详情页首次加载：失败显示重试，否则转圈。
class DetailLoadingGuard extends StatelessWidget {
  final bool failed;
  final VoidCallback onRetry;

  const DetailLoadingGuard({
    super.key,
    required this.failed,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: failed
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('加载失败'),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
              ],
            )
          : const CircularProgressIndicator(),
    );
  }
}

/// 详情页「标签 + 值」行；[ok] 非空时在尾部显示对勾/叉号。
class DetailInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final double labelWidth;
  final bool? ok;

  const DetailInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 150,
    this.ok,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: cs.onSurface.withValues(alpha: 0.7));
    final body = ok == null
        ? Theme.of(context).textTheme.bodySmall
        : Theme.of(context).textTheme.bodySmall?.copyWith(
              color: ok! ? null : cs.error,
              fontWeight: ok! ? null : FontWeight.w600,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: muted),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: body,
            ),
          ),
          if (ok != null)
            Icon(
              ok! ? Icons.check : Icons.close,
              size: 14,
              color: ok! ? cs.primary : cs.error,
            ),
        ],
      ),
    );
  }
}

/// 详情页窄屏排序按钮：显示当前方向，点击切换。
class LibrarySortButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool ascending;
  final VoidCallback onTap;

  /// 是否使用详情页统一的紧凑内边距（格式页沿用默认内边距）。
  final bool padded;

  const LibrarySortButton({
    super.key,
    required this.label,
    required this.selected,
    required this.ascending,
    required this.onTap,
    this.padded = true,
  });

  @override
  Widget build(BuildContext context) {
    final arrow = selected ? (ascending ? ' ↑' : ' ↓') : '';
    return OutlinedButton(
      style: padded
          ? OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            )
          : OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: onTap,
      child: Text('$label$arrow'),
    );
  }
}

/// 歌曲信息详情页共用：单元格样式与异步装载。
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

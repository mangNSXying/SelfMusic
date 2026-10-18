/// 歌词/封面候选详情窗（独立弹窗，纯查看；保存/回填仍在主窗底部执行）。
///
/// 主窗列表不再内嵌预览，候选行尾「查看」打开本窗：
/// - [LyricDetailDialog]：完整歌词（解析后逐行）+ 候选元数据；QQ/网易候选
///   在窗内懒取正文，取到后经 [LyricDetailDialog.onLoaded] 回填主窗列表。
/// - [CoverDetailDialog]：大图 + 标签 + 元数据；懒取字节，取到后经
///   [CoverDetailDialog.onLoaded] 回主窗缓存（保存免二次下载）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../services/online_meta/online_meta_models.dart';
import '../utils/lrc_parser.dart';

class LyricDetailDialog extends StatefulWidget {
  final OnlineLyricCandidate candidate;

  /// 懒取正文（返回带正文的候选；主窗传 `_svc.ensureLyrics`）。
  final Future<OnlineLyricCandidate> Function(OnlineLyricCandidate) ensure;

  /// 是否当前列表最佳匹配（徽标展示）。
  final bool isBest;

  /// 懒取到完整正文后回调（主窗回填列表，徽标随之更新）。
  final void Function(OnlineLyricCandidate full)? onLoaded;

  const LyricDetailDialog({
    super.key,
    required this.candidate,
    required this.ensure,
    this.isBest = false,
    this.onLoaded,
  });

  @override
  State<LyricDetailDialog> createState() => _LyricDetailDialogState();
}

class _LyricDetailDialogState extends State<LyricDetailDialog> {
  late OnlineLyricCandidate _c;
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _c = widget.candidate;
    if (!_c.hasContent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final full = await widget.ensure(_c);
      if (!mounted) return;
      setState(() {
        _c = full;
        _loading = false;
        if (!full.hasContent) _error = '该候选暂无歌词正文（换一个候选或换源）';
      });
      if (full.hasContent) widget.onLoaded?.call(full);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '取词失败：${_dioMsg(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '取词失败：$e';
      });
    }
  }

  static String _dioMsg(DioException e) {
    final code = e.response?.statusCode;
    if (code != null) return 'HTTP $code';
    return e.message ?? e.type.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final hasSync = (c.syncedLyrics ?? '').contains('[');
    final badge = c.hasContent
        ? (hasSync ? '同步 LRC' : '纯文本')
        : (_loading ? '正文加载中…' : '暂无正文');
    return AlertDialog(
      title: const Text('歌词详情'),
      content: SizedBox(
        width: 520,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${c.trackName} — ${c.artistName}',
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              '${c.source} · ${c.albumName.isEmpty ? '未知专辑' : c.albumName}'
              '${c.durationSec != null ? ' · ${_fmtDur(c.durationSec!)}' : ''}'
              ' · 匹配 ${c.matchWeight.toStringAsFixed(2)}'
              '${widget.isBest ? ' · 最佳匹配' : ''} · $badge',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
            ),
            const Divider(height: 16),
            Expanded(child: _body()),
          ],
        ),
      ),
      actions: [
        if (_error.isNotEmpty && !_c.hasContent && !_loading)
          TextButton(onPressed: _load, child: const Text('重试')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _body() {
    if (_loading && !_c.hasContent) {
      return const Center(child: CircularProgressIndicator());
    }
    final content = _c.saveContent;
    if (content.isEmpty) {
      return Center(
        child: Text(_error.isEmpty ? '该候选暂无歌词正文' : _error,
            textAlign: TextAlign.center),
      );
    }
    String text;
    try {
      final p = parseLyrics(content);
      text = p.lines.isNotEmpty
          ? p.lines
              .map((e) =>
                  e.translation == null ? e.text : '${e.text}\n${e.translation}')
              .join('\n')
          : (p.plain ?? content).trim();
    } catch (_) {
      text = content.trim();
    }
    return Scrollbar(
      child: SingleChildScrollView(
        child: SelectableText(text,
            style: const TextStyle(fontSize: 13, height: 1.7)),
      ),
    );
  }

  static String _fmtDur(double sec) {
    final s = sec.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// 封面详情窗：大图 + 标签 + 元数据。
///
/// 主窗已缓存时传 [initialBytes] 直接展示；否则调 [load] 懒取（加载/失败态）。
/// 取到后回调 [onLoaded] 供主窗缓存。
class CoverDetailDialog extends StatefulWidget {
  final String header;
  final List<String> metaLines;
  final Future<({Uint8List bytes, String label})?> Function() load;
  final Uint8List? initialBytes;
  final String initialLabel;
  final void Function(Uint8List bytes, String label)? onLoaded;

  const CoverDetailDialog({
    super.key,
    required this.header,
    required this.metaLines,
    required this.load,
    this.initialBytes,
    this.initialLabel = '',
    this.onLoaded,
  });

  @override
  State<CoverDetailDialog> createState() => _CoverDetailDialogState();
}

class _CoverDetailDialogState extends State<CoverDetailDialog> {
  Uint8List? _bytes;
  String _label = '';
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialBytes != null && widget.initialBytes!.isNotEmpty) {
      _bytes = widget.initialBytes;
      _label = widget.initialLabel;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final c = await widget.load();
      if (!mounted) return;
      if (c == null) {
        setState(() {
          _loading = false;
          _error = '该候选无封面（换一个候选或换源）';
        });
        return;
      }
      setState(() {
        _bytes = c.bytes;
        _label = c.label;
        _loading = false;
      });
      widget.onLoaded?.call(c.bytes, c.label);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '封面下载失败：${_dioMsg(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '封面下载失败：$e';
      });
    }
  }

  static String _dioMsg(DioException e) {
    final code = e.response?.statusCode;
    if (code != null) return 'HTTP $code';
    return e.message ?? e.type.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('封面详情'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.header,
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            for (final line in widget.metaLines)
              Text(line,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.65)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            const Divider(height: 16),
            Expanded(child: _imageArea()),
            if (_label.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        if (_error.isNotEmpty && _bytes == null && !_loading)
          TextButton(onPressed: _load, child: const Text('重试')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _imageArea() {
    if (_bytes != null) {
      return Center(
        child: Image.memory(_bytes!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const Text('图片无法解码（换一个候选）',
                textAlign: TextAlign.center)),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Text(_error.isEmpty ? '无预览' : _error,
          textAlign: TextAlign.center),
    );
  }
}

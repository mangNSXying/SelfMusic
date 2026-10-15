import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../data/sources/music_source.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../services/tag_embed_service.dart';
import 'app_toast.dart';

/// 嵌入确认＋进度对话框（纯手动入口，由“修改信息”弹窗打开）。
///
/// 确认页：目标文件、可嵌入内容（歌词/封面）、流量提示；
/// 执行页：阶段 + 进度条 + 取消；成功返回 true（调用方刷新），失败留窗显错。
class EmbedProgressDialog extends StatefulWidget {
  final Song song;
  const EmbedProgressDialog({super.key, required this.song});

  @override
  State<EmbedProgressDialog> createState() => _EmbedProgressDialogState();
}

class _EmbedProgressDialogState extends State<EmbedProgressDialog> {
  bool _started = false;
  bool _aborted = false;
  EmbedPhase? _phase;
  double? _fraction;
  String _error = '';

  bool _loading = true;
  String? _target;
  bool _hasLyrics = false;
  bool _hasCover = false;
  int _fileSize = 0;
  bool _isLocal = false;
  String? _denyReason;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final direct = context.read<DirectSourceManager>();
    final src = direct.sourceByKey(widget.song.sourceKey);
    if (!widget.song.isDirect) {
      if (mounted) {
        setState(() {
          _loading = false;
          _denyReason = '服务端歌曲没有文件，无法嵌入';
        });
      }
      return;
    }
    if (src == null || !src.supportsWrite) {
      if (mounted) {
        setState(() {
          _loading = false;
          _denyReason = '该源不支持写入，无法嵌入';
        });
      }
      return;
    }
    try {
      final svc = TagEmbedService(index: direct.index, settings: direct.settings);
      final content = await svc.embeddableContent(widget.song);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _target = src.displayPath(widget.song);
        _hasLyrics = content?.lyrics != null;
        _hasCover = content?.coverBytes != null;
        _fileSize = widget.song.fileSize;
        _isLocal = src.kind == SourceKind.local;
        if (content == null) _denyReason = '没有可嵌入的内容（歌词与封面均无）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _denyReason = '检查可嵌入内容失败：$e';
      });
    }
  }

  bool _isCurrentPlaying() {
    final player = context.read<PlayerProvider>();
    final cur = player.current;
    return cur != null &&
        cur.sourceKey == widget.song.sourceKey &&
        cur.sourceRef == widget.song.sourceRef &&
        player.playing;
  }

  Future<void> _start() async {
    if (_isCurrentPlaying()) {
      AppToast.show('正在播放该歌曲，请先暂停', isError: true);
      return;
    }
    setState(() {
      _started = true;
      _aborted = false;
      _error = '';
      _phase = EmbedPhase.downloading;
      _fraction = 0;
    });
    try {
      final direct = context.read<DirectSourceManager>();
      final src = direct.sourceByKey(widget.song.sourceKey);
      if (src == null) throw StateError('播放源不在本机');
      final svc =
          TagEmbedService(index: direct.index, settings: direct.settings);
      await svc.embedSong(
        widget.song,
        src,
        onProgress: (phase, fraction) {
          if (!mounted) return;
          setState(() {
            _phase = phase;
            _fraction = fraction;
          });
        },
        shouldAbort: () => _aborted,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      AppToast.show('已嵌入到文件并清理 sidecar', isError: false);
    } on PreloadAbortedException {
      if (!mounted) return;
      setState(() {
        _started = false;
        _error = '已取消（源文件未动）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('嵌入到文件'),
      content: SizedBox(
        width: 340,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()))
            : _denyReason != null
                ? Text(_denyReason!, textAlign: TextAlign.center)
                : _started
                    ? _progressBody(cs)
                    : _confirmBody(cs),
      ),
      actions: [
        if (_loading || _denyReason != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          )
        else if (!_started) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _start,
            child: const Text('开始嵌入'),
          ),
        ] else if (_error.isNotEmpty) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _started = false;
                _error = '';
                _phase = null;
                _fraction = null;
              });
            },
            child: const Text('重试'),
          ),
        ] else ...[
          TextButton(
            onPressed: () {
              setState(() => _aborted = true);
            },
            child: const Text('取消'),
          ),
        ],
      ],
    );
  }

  Widget _confirmBody(ColorScheme cs) {
    final hint = TextStyle(
        fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('目标', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(_target ?? widget.song.sourceRef,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 12),
        Text('将嵌入', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(_hasLyrics ? Icons.check : Icons.close,
                size: 18,
                color: _hasLyrics ? Colors.green : cs.outline),
            const SizedBox(width: 4),
            const Text('歌词'),
            const SizedBox(width: 16),
            Icon(_hasCover ? Icons.check : Icons.close,
                size: 18,
                color: _hasCover ? Colors.green : cs.outline),
            const SizedBox(width: 4),
            const Text('封面'),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _isLocal
              ? '本地文件：同目录 tmp+rename 原子替换，无上传流量。'
              : '远端文件：将产生约 ${_fmtBytes(_fileSize * 2)} 流量（整首下载＋整首上传），建议 Wi-Fi 下操作。',
          style: hint,
        ),
        const SizedBox(height: 4),
        Text(
          '同名 sidecar（<stem>.lrc / cover.jpg）将在验签通过后删除；应用缓存保留；同曲在播需先暂停。',
          style: hint,
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_error, style: TextStyle(color: cs.error, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _progressBody(ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_phase?.label ?? '准备中…',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        _fraction == null
            ? const LinearProgressIndicator()
            : LinearProgressIndicator(value: _fraction!.clamp(0.0, 1.0)),
        if (_fraction != null) ...[
          const SizedBox(height: 4),
          Text('${(_fraction!.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.6))),
        ],
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_error,
              style: TextStyle(color: cs.error, fontSize: 13)),
        ],
      ],
    );
  }
}

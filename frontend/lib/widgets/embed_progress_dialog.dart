import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../services/tag_embed_service.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';

/// 嵌入流程结果（对话框返回值；[detail] 为失败/跳过原因）。
enum EmbedOutcomeStatus { embedded, cancelled, failed, skipped }

class EmbedOutcome {
  final EmbedOutcomeStatus status;
  final String? detail;
  const EmbedOutcome(this.status, [this.detail]);
}

/// 嵌入确认＋进度对话框。
///
/// 手动入口（“修改信息”弹窗）：确认页展示目标/内容/流量提示，执行页显示
/// 阶段与进度；成功返回 [EmbedOutcomeStatus.embedded]。
/// 自动入口（保存口径＝内嵌到歌曲）：[autoStart] 跳过确认页直接执行，
/// 不可嵌入/取消/失败直接以结果返回，由调用方合并提示。
class EmbedProgressDialog extends StatefulWidget {
  final Song song;

  /// 跳过确认页，加载完成后立即开始（自动内嵌）。
  final bool autoStart;

  /// 成功后是否自行 toast（自动内嵌由调用方统一提示，避免双 toast）。
  final bool toastOnSuccess;

  const EmbedProgressDialog({
    super.key,
    required this.song,
    this.autoStart = false,
    this.toastOnSuccess = true,
  });

  @override
  State<EmbedProgressDialog> createState() => _EmbedProgressDialogState();
}

class _EmbedProgressDialogState extends State<EmbedProgressDialog> {
  bool _started = false;
  bool _aborted = false;
  EmbedPhase? _phase;
  double? _fraction;
  String _error = '';

  /// 写盘前因同曲在播而自动暂停（流程结束后恢复）。
  bool _pausedByUs = false;

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
    String? deny;
    if (!widget.song.isDirect) {
      deny = '服务端歌曲没有文件，无法嵌入';
    } else if (src == null || !src.supportsWrite) {
      deny = '该源不支持写入，无法嵌入';
    } else {
      try {
        final svc =
            TagEmbedService(index: direct.index, settings: direct.settings);
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
        if (_denyReason != null) {
          if (widget.autoStart) {
            Navigator.of(context).pop(
                EmbedOutcome(EmbedOutcomeStatus.skipped, _denyReason));
          }
          return; // 手动入口停在确认页（不可嵌入时显示原因）
        }
        if (widget.autoStart) unawaited(_start());
        return;
      } catch (e) {
        deny = '检查可嵌入内容失败：$e';
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _denyReason = deny;
    });
    if (widget.autoStart) {
      // 自动入口没有“确认页”可留：直接返回原因，由保存流程提示。
      Navigator.of(context)
          .pop(EmbedOutcome(EmbedOutcomeStatus.skipped, deny));
    }
  }

  Future<void> _start() async {
    final player = context.read<PlayerProvider>();
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
        // 写盘/上传前：正在播放的恰是本曲时自动暂停（等引擎实际暂停），
        // 流程结束（成功/失败/取消）统一在 finally 恢复。
        beforeWrite: () async {
          final cur = player.current;
          final same = cur != null &&
              cur.sourceKey == widget.song.sourceKey &&
              cur.sourceRef == widget.song.sourceRef;
          if (same) _pausedByUs = await player.pauseForFileWrite();
        },
      );
      if (!mounted) return;
      Navigator.of(context)
          .pop(const EmbedOutcome(EmbedOutcomeStatus.embedded));
      if (widget.toastOnSuccess) {
        AppToast.show('已嵌入到文件并清理 sidecar', isError: false);
      }
    } on PreloadAbortedException {
      if (!mounted) return;
      if (widget.autoStart) {
        Navigator.of(context)
            .pop(const EmbedOutcome(EmbedOutcomeStatus.cancelled));
        return;
      }
      setState(() {
        _started = false;
        _error = '已取消（源文件未动）';
      });
    } catch (e) {
      if (!mounted) return;
      if (widget.autoStart) {
        Navigator.of(context)
            .pop(EmbedOutcome(EmbedOutcomeStatus.failed, '$e'));
        return;
      }
      setState(() => _error = '$e');
    } finally {
      // 恢复播放与窗口是否还在无关（用捕获的 provider，不依赖 context）。
      if (_pausedByUs) {
        _pausedByUs = false;
        await player.toggle();
      }
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
          appDialogCloseAction(context)
        else if (!_started) ...[
          ...appDialogActions(
            context,
            confirmLabel: '开始嵌入',
            onCancel: () => Navigator.of(context).pop(),
            onConfirm: _start,
          ),
        ] else if (_error.isNotEmpty) ...[
          ...appDialogActions(
            context,
            cancelLabel: '关闭',
            confirmLabel: '重试',
            onCancel: () => Navigator.of(context).pop(),
            onConfirm: () {
              setState(() {
                _started = false;
                _error = '';
                _phase = null;
                _fraction = null;
              });
            },
          ),
        ] else
          TextButton(
            onPressed: _aborted
                ? null
                : () {
                    setState(() => _aborted = true);
                  },
            child: Text(_aborted ? '取消中…' : '取消'),
          ),
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
          '同名 sidecar（<stem>.lrc / cover.jpg）将在验签通过后删除；应用缓存保留；同曲在播将在写盘前自动暂停，完成后自动恢复。',
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
        if (_aborted) ...[
          const SizedBox(height: 8),
          Text('已请求取消：正在上传时会等整传完成后还原原文件（不再半截掐断）。',
              style: TextStyle(fontSize: 12, color: cs.error)),
        ],
      ],
    );
  }
}

/// 保存后按设置自动内嵌（设置→歌曲→在线元数据＝内嵌到歌曲）。
///
/// 返回 null 表示当前不是内嵌模式（调用方沿用缓存/sidecar 口径提示）；
/// 否则返回执行结果——[EmbedOutcomeStatus.skipped] 为条件不满足未执行
/// （服务端歌/源不可写/格式不支持），由调用方合并进保存提示。
Future<EmbedOutcome?> embedAfterSaveIfEnabled(
    BuildContext context, Song song) async {
  final direct = context.read<DirectSourceManager>();
  if (direct.settings.onlineMetaSaveMode != OnlineMetaSaveMode.embed) {
    return null;
  }
  if (!song.isDirect) {
    return const EmbedOutcome(EmbedOutcomeStatus.skipped, '服务端歌曲没有文件');
  }
  final src = direct.sourceByKey(song.sourceKey);
  if (src == null || !src.supportsWrite) {
    return const EmbedOutcome(EmbedOutcomeStatus.skipped, '该源不支持写入');
  }
  if (!TagEmbedService.supportsFormat(song)) {
    final fmt = TagEmbedService.formatOf(song);
    return EmbedOutcome(EmbedOutcomeStatus.skipped,
        '${fmt.isEmpty ? '该格式' : fmt.toUpperCase()} 暂不支持内嵌');
  }
  final r = await showDialog<EmbedOutcome>(
    context: context,
    // 执行中含“整传后还原”等收尾逻辑，禁止点外部误关（取消走弹窗按钮）。
    barrierDismissible: false,
    builder: (_) => EmbedProgressDialog(
      song: song,
      autoStart: true,
      toastOnSuccess: false,
    ),
  );
  return r ?? const EmbedOutcome(EmbedOutcomeStatus.cancelled);
}

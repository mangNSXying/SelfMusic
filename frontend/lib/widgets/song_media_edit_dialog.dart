import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/audio_metadata.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../services/online_meta/online_meta_service.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'online_meta_dialog.dart';

/// 封面查看/更换窗口：显示当前封面，支持选择本地图片与在线获取。
///
/// 由「歌曲信息」窗封面区点击进入；保存走 [OnlineMetaService.applyCover]。
class CoverEditWindow extends StatefulWidget {
  final Song song;
  const CoverEditWindow({super.key, required this.song});

  @override
  State<CoverEditWindow> createState() => _CoverEditWindowState();
}

class _CoverEditWindowState extends State<CoverEditWindow> {
  String? _path;

  /// 本地新选、尚未保存的封面字节（预览优先展示；保存时才落库/写回）。
  Uint8List? _mem;
  bool _busy = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _path = widget.song.coverPath;
  }

  Future<void> _pickFile() async {
    if (_busy || _saving) return;
    setState(() => _busy = true);
    try {
      final f = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: '图片', extensions: ['jpg', 'jpeg', 'png', 'webp'])
      ]);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      if (!isCompleteImageBytes(bytes)) {
        if (mounted) AppToast.show('所选文件不是完整图片', isError: true);
        return;
      }
      if (!mounted) return;
      setState(() => _mem = Uint8List.fromList(bytes));
      AppToast.show('已选择新封面，点击保存生效', isError: false);
    } catch (e) {
      if (mounted) AppToast.error(e, '选择封面失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final bytes = _mem;
    if (bytes == null) {
      // 在线获取已在子窗内保存；这里只关闭。
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _saving = true);
    try {
      final direct = context.read<DirectSourceManager>();
      final player = context.read<PlayerProvider>();
      final svc = OnlineMetaService(
          index: direct.index, settings: direct.settings);
      final r = await svc.applyCover(widget.song, bytes,
          src: direct.sourceByKey(widget.song.sourceKey));
      final updated = direct.index
          .songByRef(widget.song.sourceKey, widget.song.sourceRef);
      if (updated != null) {
        // 先通知再判 mounted：保存后立刻关窗也不能丢掉全局刷新信号。
        direct.notifySongMetaChanged();
        player.refreshSongMeta(updated);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      AppToast.show(
          r.sidecarPath != null ? '封面已保存并覆盖 ${r.sidecarPath}' : '封面已保存',
          isError: false);
    } catch (e) {
      if (mounted) AppToast.error(e, '保存封面失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openOnline() async {
    if (_busy || _saving) return;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          OnlineMetaDialog(song: widget.song, initialTab: 1),
    );
    if (!mounted) return;
    final direct = context.read<DirectSourceManager>();
    final fresh = direct.index
        .songByRef(widget.song.sourceKey, widget.song.sourceRef);
    setState(() {
      // 本地待保存选择保留（预览仍以 _mem 为准）；在线结果只刷新已保存路径。
      _path = (fresh ?? widget.song).coverPath;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget preview;
    if (_mem != null && _mem!.isNotEmpty) {
      preview = Image.memory(_mem!, fit: BoxFit.contain);
    } else {
      var ok = false;
      try {
        ok = _path != null &&
            _path!.isNotEmpty &&
            File(_path!).existsSync();
      } catch (_) {
        ok = false;
      }
      preview = ok
          ? Image.file(File(_path!), fit: BoxFit.contain)
          : const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_not_supported_outlined, size: 48),
                SizedBox(height: 8),
                Text('暂无封面'),
              ],
            );
    }
    return AlertDialog(
      title: Text(_mem != null ? '封面 •未保存' : '封面'),
      content: SizedBox(
        width: 340,
        height: 400,
        child: Column(
          children: [
            Expanded(child: Center(child: preview)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_busy || _saving) ? null : _pickFile,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(_busy ? '处理中…' : '选择封面'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_busy || _saving) ? null : _openOnline,
                    icon: const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('在线获取'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: appDialogActions(
        context,
        confirmLabel: _saving ? '保存中…' : '保存',
        confirmEnabled: !_busy && !_saving,
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: _save,
      ),
    );
  }
}

/// 歌词查看/编辑窗口：显示当前歌词（可编辑），支持选择文件、在线获取、
/// 撤回/反撤回与保存。保存遵循设置口径（应用缓存必写，sidecar 按配置）。
class LyricsEditWindow extends StatefulWidget {
  final Song song;
  const LyricsEditWindow({super.key, required this.song});

  @override
  State<LyricsEditWindow> createState() => _LyricsEditWindowState();
}

class _LyricsEditWindowState extends State<LyricsEditWindow> {
  late final TextEditingController _controller;
  bool _busy = false;
  bool _dirty = false;

  // 轻量历史栈（逐次变更记录，50 条封顶；歌词文本小，全量存无压力）。
  final List<String> _undo = [];
  final List<String> _redo = [];
  String _lastText = '';
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final initial = context
            .read<DirectSourceManager>()
            .index
            .lyricsOf(widget.song.sourceKey, widget.song.sourceRef) ??
        '';
    _controller = TextEditingController(text: initial);
    _lastText = initial;
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_applying) return;
    _redo.clear();
    _undo.add(_lastText);
    if (_undo.length > 50) _undo.removeAt(0);
    _lastText = _controller.text;
    if (!_dirty) setState(() => _dirty = true);
  }

  void _setText(String v) {
    _applying = true;
    try {
      _controller.text = v;
    } finally {
      _applying = false;
    }
    _lastText = v;
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    _redo.add(_controller.text);
    _setText(_undo.removeLast());
    setState(() => _dirty = true);
  }

  void _redoOnce() {
    if (_redo.isEmpty) return;
    _undo.add(_controller.text);
    _setText(_redo.removeLast());
    setState(() => _dirty = true);
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: '歌词', extensions: ['lrc'])
      ]);
      if (f == null) return;
      final raw = await f.readAsBytes();
      var text = '';
      try {
        text = utf8.decode(raw);
      } catch (_) {
        text = utf8.decode(raw, allowMalformed: true);
      }
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      if (text.trim().isEmpty) {
        if (mounted) AppToast.show('所选歌词文件为空', isError: true);
        return;
      }
      _setText(text);
      setState(() => _dirty = true);
    } catch (e) {
      if (mounted) AppToast.error(e, '读取歌词文件失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOnline() async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          OnlineMetaDialog(song: widget.song, initialTab: 0),
    );
    if (!mounted) return;
    // 用户已有未保存编辑时保留现状，否则用在线新值回填。
    if (_dirty) {
      AppToast.show('已保留当前编辑（在线结果未自动覆盖）', isError: false);
      return;
    }
    final lyrics = context
        .read<DirectSourceManager>()
        .index
        .lyricsOf(widget.song.sourceKey, widget.song.sourceRef);
    if (lyrics != null && lyrics != _controller.text) {
      _setText(lyrics);
    }
  }

  Future<void> _save() async {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      AppToast.show('歌词为空，不保存', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final direct = context.read<DirectSourceManager>();
      final player = context.read<PlayerProvider>();
      final svc = OnlineMetaService(
          index: direct.index, settings: direct.settings);
      final r = await svc.applyLyrics(widget.song, text,
          src: direct.sourceByKey(widget.song.sourceKey));
      // 先通知再判 mounted：保存后立刻关窗也不能丢掉全局刷新信号。
      direct.notifySongMetaChanged();
      player.reloadLyricsIfCurrent(widget.song);
      if (!mounted) return;
      setState(() => _dirty = false);
      Navigator.of(context).pop(true);
      AppToast.show(
          r.sidecarPath != null
              ? '歌词已保存并覆盖 ${r.sidecarPath}'
              : r.sidecarSkipped
                  ? '歌词已保存（该源不支持写回，已跳过 sidecar）'
                  : '歌词已保存',
          isError: false);
    } catch (e) {
      if (mounted) AppToast.error(e, '保存歌词失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_dirty ? '歌词 •未保存' : '歌词'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _undo.isEmpty ? null : _undoOnce,
                  icon: const Icon(Icons.undo),
                  tooltip: '撤回',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: _redo.isEmpty ? null : _redoOnce,
                  icon: const Icon(Icons.redo),
                  tooltip: '反撤回',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '暂无歌词，可粘贴、选择文件或在线获取',
                  border: const OutlineInputBorder(),
                  filled: _dirty ? true : false,
                  fillColor: _dirty ? cs.primary.withValues(alpha: 0.04) : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFile,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('选择歌词'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _openOnline,
                    icon: const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('在线获取'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: appDialogActions(
        context,
        confirmLabel: _busy ? '保存中…' : '保存',
        confirmEnabled: !_busy,
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: _save,
      ),
    );
  }
}

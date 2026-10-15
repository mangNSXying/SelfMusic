import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/local/audio_metadata.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../services/online_meta/online_meta_service.dart';
import 'app_toast.dart';
import 'embed_progress_dialog.dart';
import 'online_meta_dialog.dart';

/// 修改信息弹窗（全源）：标题/歌手/专辑/年份可编辑，封面/歌词进子窗口。
///
/// 直连歌落库并标记扫描保护；服务端歌（后端只读）写入本地覆盖层，刷新即生效。
/// 纯手动入口：本弹窗只由用户点开（播放页封面菜单/歌曲列表三点菜单），
/// 不做任何自动搜刮。在线保存后用索引最新行回填本窗输入框（用户已改的
/// 字段保留，不覆盖）。
class EditSongMetaDialog extends StatefulWidget {
  final Song song;
  const EditSongMetaDialog({super.key, required this.song});

  @override
  State<EditSongMetaDialog> createState() => _EditSongMetaDialogState();
}

class _EditSongMetaDialogState extends State<EditSongMetaDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _albumArtist;
  late final TextEditingController _album;
  late final TextEditingController _year;

  String? _coverPath;
  String _lyricSummary = '无';

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.song.title);
    _artist = TextEditingController(text: widget.song.artist ?? '');
    _albumArtist = TextEditingController(text: widget.song.albumArtist ?? '');
    _album = TextEditingController(text: widget.song.albumName ?? '');
    _year = TextEditingController(
        text: widget.song.year == null ? '' : '${widget.song.year}');
    _coverPath = widget.song.coverPath;
    _lyricSummary = _summarize(
        context.read<DirectSourceManager>().index.lyricsOf(
            widget.song.sourceKey, widget.song.sourceRef));
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _albumArtist.dispose();
    _album.dispose();
    _year.dispose();
    super.dispose();
  }

  static String _summarize(String? lyrics) {
    if (lyrics == null || lyrics.trim().isEmpty) return '无';
    final lines =
        lyrics.split(RegExp(r'\r?\n')).where((e) => e.trim().isNotEmpty);
    if (!lyrics.contains('[')) return '纯文本';
    return '${lines.length} 行';
  }

  void _refreshMediaState() {
    final direct = context.read<DirectSourceManager>();
    final fresh = direct.index.songByRef(
        widget.song.sourceKey, widget.song.sourceRef);
    setState(() {
      _coverPath = (fresh ?? widget.song).coverPath;
      _lyricSummary = _summarize(direct.index
          .lyricsOf(widget.song.sourceKey, widget.song.sourceRef));
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      AppToast.error(StateError('标题不能为空'));
      return;
    }
    // 字段语义：null=未改动不写；''=清空为未知；其余=新值。
    String? delta(String input, String? current) {
      final v = input.trim();
      if (v == (current ?? '')) return null;
      return v.isEmpty ? '' : v;
    }

    // 年份：null 且不清=不修改；数字=新值；清空（原有值→留空）=clearYear。
    final yearInput = _year.text.trim();
    final yearOrig = widget.song.year;
    int? year;
    var clearYear = false;
    if (yearInput != (yearOrig == null ? '' : '$yearOrig')) {
      if (yearInput.isEmpty) {
        if (yearOrig != null) clearYear = true;
      } else {
        year = int.tryParse(yearInput);
      }
    }

    final direct = context.read<DirectSourceManager>();
    final updated = await direct.updateSongMeta(
      widget.song,
      title: delta(title, widget.song.title),
      artist: delta(_artist.text, widget.song.artist),
      albumArtist: delta(_albumArtist.text, widget.song.albumArtist),
      album: delta(_album.text, widget.song.albumName),
      year: year,
      clearYear: clearYear,
    );
    if (!mounted) return;
    if (updated != null) {
      context.read<PlayerProvider>().refreshSongMeta(updated);
    }
    Navigator.of(context).pop();
    AppToast.show(
        widget.song.isDirect ? '已保存歌曲信息（扫描不再覆盖）' : '已保存歌曲信息（本地覆盖）',
        isError: false);
  }

  /// 打开在线获取（手动）：保存后用索引最新行回填本窗（用户已改字段保留）。
  Future<void> _openOnline() async {
    await showDialog<void>(
      context: context,
      builder: (_) => OnlineMetaDialog(song: widget.song),
    );
    if (!mounted) return;
    final direct = context.read<DirectSourceManager>();
    final fresh =
        direct.index.songByRef(widget.song.sourceKey, widget.song.sourceRef);
    // 服务端歌无 idx_songs 行时 songByRef 为空：保留本窗现状。
    final f = fresh ?? widget.song;
    void refill(TextEditingController c, String? orig, String? now) {
      // 仅当用户没动该字段（仍等于打开时的旧值）才用在线新值覆盖。
      if (c.text == (orig ?? '') && c.text != (now ?? '')) {
        c.text = now ?? '';
      }
    }

    setState(() {
      refill(_title, widget.song.title, f.title);
      refill(_artist, widget.song.artist, f.artist);
      refill(_albumArtist, widget.song.albumArtist, f.albumArtist);
      refill(_album, widget.song.albumName, f.albumName);
      final yOrig = widget.song.year == null ? '' : '${widget.song.year}';
      final yNow = f.year == null ? '' : '${f.year}';
      refill(_year, yOrig, yNow);
      _refreshMediaState();
    });
  }

  Future<void> _openEmbed() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => EmbedProgressDialog(song: widget.song),
    );
    if (!mounted || ok != true) return;
    _refreshMediaState();
  }

  Future<void> _openCover() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CoverEditWindow(song: widget.song),
    );
    if (!mounted) return;
    _refreshMediaState();
  }

  Future<void> _openLyrics() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _LyricsEditWindow(song: widget.song),
    );
    if (!mounted) return;
    _refreshMediaState();
  }

  @override
  Widget build(BuildContext context) {
    var hasCover = false;
    try {
      hasCover = _coverPath != null &&
          _coverPath!.isNotEmpty &&
          File(_coverPath!).existsSync();
    } catch (_) {
      hasCover = false;
    }
    // 嵌入入口可见性（同步判定）：直连 + 源可写才显示；内容有无在进度窗内再查。
    var canEmbed = false;
    try {
      final src = context
          .read<DirectSourceManager>()
          .sourceByKey(widget.song.sourceKey);
      canEmbed = widget.song.isDirect && src != null && src.supportsWrite;
    } catch (_) {
      canEmbed = false;
    }
    return AlertDialog(
      title: const Text('修改信息'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              TextField(
                controller: _artist,
                decoration:
                    const InputDecoration(labelText: '歌手（留空为未知）'),
              ),
              TextField(
                controller: _albumArtist,
                decoration:
                    const InputDecoration(labelText: '专辑歌手（留空为未知）'),
              ),
              TextField(
                controller: _album,
                decoration:
                    const InputDecoration(labelText: '专辑（留空为未知）'),
              ),
              TextField(
                controller: _year,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration:
                    const InputDecoration(labelText: '年份（留空为未知）'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: hasCover
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          File(_coverPath!),
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.broken_image_outlined),
                        ),
                      )
                    : const Icon(Icons.image_outlined),
                title: const Text('封面'),
                subtitle: Text(hasCover ? '已设置（点击查看/更换）' : '无（点击设置）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openCover,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.lyrics_outlined),
                title: const Text('歌词'),
                subtitle: Text(_lyricSummary == '无'
                    ? '无（点击设置）'
                    : '$_lyricSummary（点击查看/编辑）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openLyrics,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _openOnline,
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: const Text('在线获取元数据…'),
                    ),
                    if (canEmbed)
                      TextButton.icon(
                        onPressed: _openEmbed,
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: const Text('嵌入到文件…'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 封面查看/更换窗口：显示当前封面，支持选择本地图片与在线获取。
class _CoverEditWindow extends StatefulWidget {
  final Song song;
  const _CoverEditWindow({required this.song});

  @override
  State<_CoverEditWindow> createState() => _CoverEditWindowState();
}

class _CoverEditWindowState extends State<_CoverEditWindow> {
  String? _path;
  Uint8List? _mem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _path = widget.song.coverPath;
  }

  Future<void> _pickFile() async {
    if (_busy) return;
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
      final direct = context.read<DirectSourceManager>();
      final svc = OnlineMetaService(
          index: direct.index, settings: direct.settings);
      final r = await svc.applyCover(widget.song, bytes,
          src: direct.sourceByKey(widget.song.sourceKey));
      if (!mounted) return;
      final updated = direct.index
          .songByRef(widget.song.sourceKey, widget.song.sourceRef);
      if (updated != null) {
        direct.refresh();
        context.read<PlayerProvider>().refreshSongMeta(updated);
      }
      setState(() {
        _mem = Uint8List.fromList(bytes);
        _path = r.coverPath;
      });
      AppToast.show(
          r.sidecarPath != null ? '封面已更换并覆盖 ${r.sidecarPath}' : '封面已更换',
          isError: false);
    } catch (e) {
      if (mounted) AppToast.error(e, '选择封面失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOnline() async {
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
      _mem = null;
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
      title: const Text('封面'),
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
                    onPressed: _busy ? null : _pickFile,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(_busy ? '处理中…' : '选择封面'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openOnline,
                    icon: const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('在线获取'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 歌词查看/编辑窗口：显示当前歌词（可编辑），支持选择文件、在线获取、
/// 撤回/反撤回与保存。保存遵循设置口径（应用缓存必写，sidecar 按配置）。
class _LyricsEditWindow extends StatefulWidget {
  final Song song;
  const _LyricsEditWindow({required this.song});

  @override
  State<_LyricsEditWindow> createState() => _LyricsEditWindowState();
}

class _LyricsEditWindowState extends State<_LyricsEditWindow> {
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
      final svc = OnlineMetaService(
          index: direct.index, settings: direct.settings);
      final r = await svc.applyLyrics(widget.song, text,
          src: direct.sourceByKey(widget.song.sourceKey));
      if (!mounted) return;
      context.read<PlayerProvider>().reloadLyricsIfCurrent(widget.song);
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickFile,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('选择歌词'),
                ),
                OutlinedButton.icon(
                  onPressed: _openOnline,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('在线获取'),
                ),
                IconButton(
                  onPressed: _undo.isEmpty ? null : _undoOnce,
                  icon: const Icon(Icons.undo),
                  tooltip: '撤回',
                ),
                IconButton(
                  onPressed: _redo.isEmpty ? null : _redoOnce,
                  icon: const Icon(Icons.redo),
                  tooltip: '反撤回',
                ),
              ],
            ),
            const SizedBox(height: 8),
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
                  fillColor: _dirty
                      ? cs.primary.withValues(alpha: 0.04)
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

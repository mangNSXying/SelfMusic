import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'embed_progress_dialog.dart';
import 'online_meta_dialog.dart';
import 'song_media_edit_dialog.dart';

/// 修改信息弹窗（全源）：标题/歌手/专辑/年份可编辑，封面/歌词进子窗口。
///
/// 直连歌落库并标记扫描保护；服务端歌（后端只读）写入本地覆盖层，刷新即生效。
/// 纯手动入口：本弹窗只由用户点开（播放页封面菜单/歌曲列表三点菜单），
/// 不做任何自动搜刮。窗口存活期间监听元数据版本，在线回填/子窗编辑/
/// 后台补读落库后自动用索引最新行回填输入框（用户已改的字段保留，不覆盖）。
///
/// 封面/歌词子窗已抽到 `song_media_edit_dialog.dart`（[CoverEditWindow] /
/// [LyricsEditWindow]），供「歌曲信息」窗共用。
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

  late final DirectSourceManager _direct;
  late int _seenMetaVersion;

  String? _coverPath;
  String _lyricSummary = '无';

  /// 保存进行中（含内嵌）：阻止连点导致重复写盘/重复嵌入。
  bool _saving = false;

  /// 本窗自动回填写入过的值（每个输入框最近一次）：连续多次在线回填时，
  /// 字段仍可视为「未手改」继续跟随，而手改过的字段不再被覆盖。
  final Map<TextEditingController, String> _autoFilled = {};

  @override
  void initState() {
    super.initState();
    _direct = context.read<DirectSourceManager>();
    _seenMetaVersion = _direct.metaVersion;
    _direct.addListener(_onDirectChanged);
    _title = TextEditingController(text: widget.song.title);
    _artist = TextEditingController(text: widget.song.artist ?? '');
    _albumArtist = TextEditingController(text: widget.song.albumArtist ?? '');
    _album = TextEditingController(text: widget.song.albumName ?? '');
    _year = TextEditingController(
        text: widget.song.year == null ? '' : '${widget.song.year}');
    _coverPath = widget.song.coverPath;
    _lyricSummary = _summarize(
        _direct.index.lyricsOf(widget.song.sourceKey, widget.song.sourceRef));
  }

  @override
  void dispose() {
    _direct.removeListener(_onDirectChanged);
    _title.dispose();
    _artist.dispose();
    _albumArtist.dispose();
    _album.dispose();
    _year.dispose();
    super.dispose();
  }

  /// 元数据版本变化（在线回填/嵌入/子窗口编辑/后台补读）→ 自动回填本窗。
  /// 不再依赖关闭在线窗的返回值：保存后立即关窗、写库晚于关窗也不会漏刷新。
  void _onDirectChanged() {
    if (!mounted) return;
    final v = _direct.metaVersion;
    if (v == _seenMetaVersion) return;
    _seenMetaVersion = v;
    _refreshFromIndex();
  }

  static String _summarize(String? lyrics) {
    if (lyrics == null || lyrics.trim().isEmpty) return '无';
    final lines =
        lyrics.split(RegExp(r'\r?\n')).where((e) => e.trim().isNotEmpty);
    if (!lyrics.contains('[')) return '纯文本';
    return '${lines.length} 行';
  }

  /// 用索引最新行回填输入框与封面/歌词摘要。
  /// 用户手改过的字段保留；未手改字段（含此前自动回填的值）跟随最新行。
  void _refreshFromIndex() {
    final fresh =
        _direct.index.songByRef(widget.song.sourceKey, widget.song.sourceRef);
    // 服务端歌无 idx_songs 行时 songByRef 为空：保留本窗现状。
    final f = fresh ?? widget.song;
    void refill(TextEditingController c, String? orig, String? now) {
      final v = now ?? '';
      final baseline = _autoFilled[c] ?? (orig ?? '');
      if (c.text == baseline && c.text != v) {
        c.text = v;
        _autoFilled[c] = v;
      }
    }

    refill(_title, widget.song.title, f.title);
    refill(_artist, widget.song.artist, f.artist);
    refill(_albumArtist, widget.song.albumArtist, f.albumArtist);
    refill(_album, widget.song.albumName, f.albumName);
    final yOrig = widget.song.year == null ? '' : '${widget.song.year}';
    final yNow = f.year == null ? '' : '${f.year}';
    refill(_year, yOrig, yNow);
    setState(() {
      _coverPath = f.coverPath;
      _lyricSummary = _summarize(
          _direct.index.lyricsOf(widget.song.sourceKey, widget.song.sourceRef));
    });
  }

  Future<void> _save() async {
    if (_saving) return;
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

    _saving = true;
    try {
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
      // 内嵌口径：仅本窗“保存”按钮触发；在线获取/封面/歌词子窗只存缓存。
      final embed = await embedAfterSaveIfEnabled(context, widget.song);
      if (!mounted) return;
      Navigator.of(context).pop();
      final base = widget.song.isDirect
          ? '已保存歌曲信息（扫描不再覆盖）'
          : '已保存歌曲信息（本地覆盖）';
      AppToast.show(
        switch (embed?.status) {
          EmbedOutcomeStatus.embedded => '$base，并已将歌词/封面内嵌到歌曲文件',
          EmbedOutcomeStatus.cancelled => '$base，嵌入已取消（仅应用缓存）',
          EmbedOutcomeStatus.failed => '$base，未嵌入：${embed?.detail}',
          EmbedOutcomeStatus.skipped => '$base，未嵌入：${embed?.detail}',
          null => base,
        },
        isError: false,
      );
    } finally {
      _saving = false;
    }
  }

  /// 打开在线获取（手动）：保存后经 metaVersion 监听自动回填本窗。
  Future<void> _openOnline() async {
    await showDialog<void>(
      context: context,
      builder: (_) => OnlineMetaDialog(song: widget.song),
    );
    if (!mounted) return;
    // 兜底同步一次（幂等）：覆盖在线窗未走 notifySongMetaChanged 的旧路径。
    _refreshFromIndex();
  }

  Future<void> _openEmbed() async {
    final result = await showDialog<EmbedOutcome>(
      context: context,
      // 执行中含“整传后还原”等收尾逻辑，禁止点外部误关（取消走弹窗按钮）。
      barrierDismissible: false,
      builder: (_) => EmbedProgressDialog(song: widget.song),
    );
    if (!mounted || result?.status != EmbedOutcomeStatus.embedded) return;
    _refreshFromIndex();
  }

  Future<void> _openCover() async {
    await showDialog<void>(
      context: context,
      builder: (_) => CoverEditWindow(song: widget.song),
    );
    if (!mounted) return;
    _refreshFromIndex();
  }

  Future<void> _openLyrics() async {
    await showDialog<void>(
      context: context,
      builder: (_) => LyricsEditWindow(song: widget.song),
    );
    if (!mounted) return;
    _refreshFromIndex();
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
                      label: const Text('在线获取'),
                    ),
                    if (canEmbed)
                      TextButton.icon(
                        onPressed: _openEmbed,
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: const Text('嵌入文件'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: appDialogActions(
        context,
        confirmLabel: '保存',
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: _save,
      ),
    );
  }
}

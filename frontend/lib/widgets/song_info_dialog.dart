import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../theme/app_metrics.dart';
import '../utils/cover_thumb.dart';
import '../utils/duration_format.dart';
import '../utils/play_progress.dart';
import '../utils/play_stats.dart';
import '../utils/url_display.dart';
import '../utils/zh_variant.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'embed_progress_dialog.dart';
import 'online_meta_dialog.dart';
import 'song_media_edit_dialog.dart';
import 'song_row_view.dart';

/// 歌曲信息弹窗（唯一入口，全源）：封面 + 基本信息 / 歌词 / 音频信息 /
/// 播放统计 / 来源。
///
/// 播放页封面「更多」与歌曲列表行三点菜单共用。以前拆成「歌曲信息」
/// （只读）与「修改信息」（表单）两窗，现合并为一窗：
/// - **基本信息就地编辑**：字段点击变输入框，回车/点别处收起；
///   未改动时底部只有「关闭」，有改动才出现「保存」并启用关闭保护；
/// - 封面区点击进封面子窗，歌词行走歌词子窗；
/// - 「在线获取」「嵌入文件」仍是按钮 → 各自新开窗口。
///
/// 窗口存活期间监听元数据版本：在线回填/子窗编辑/后台补读落库后用索引
/// 最新行回填，用户已手改的字段保留，不覆盖。
class SongInfoDialog extends StatefulWidget {
  final Song song;
  const SongInfoDialog({super.key, required this.song});

  @override
  State<SongInfoDialog> createState() => _SongInfoDialogState();
}

class _SongInfoDialogState extends State<SongInfoDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _albumArtist;
  late final TextEditingController _album;
  late final TextEditingController _year;

  late final DirectSourceManager _direct;
  late int _seenMetaVersion;

  /// 本窗最新歌曲行（索引最新行；服务端歌无行时回落 [widget.song]）。
  late Song _cur;

  String _lyricSummary = '无';

  /// 每个输入框最后一次「已持久化」的值：脏检测基线 + 自动回填的判定依据。
  /// 值仍与基线相同的字段视为未手改，可继续跟随索引最新行。
  final Map<TextEditingController, String> _baseline = {};

  /// 当前处于编辑态的字段键（同一时刻只有一个）。
  String? _editingField;

  /// 当前选中的只读字段键（路径展开用）。
  String? _selected;

  bool _dirty = false;

  /// 标题是否非空。保存按钮可用性依赖它，所以要在标题变化时一起 setState。
  bool _titleFilled = true;
  bool _saving = false;

  Song get song => _cur;

  @override
  void initState() {
    super.initState();
    _direct = context.read<DirectSourceManager>();
    _seenMetaVersion = _direct.metaVersion;
    _direct.addListener(_onDirectChanged);

    _cur = widget.song;
    _title = TextEditingController(text: _cur.title);
    _artist = TextEditingController(text: _cur.artist ?? '');
    _albumArtist = TextEditingController(text: _cur.albumArtist ?? '');
    _album = TextEditingController(text: _cur.albumName ?? '');
    _year = TextEditingController(
        text: _cur.year == null ? '' : '${_cur.year}');
    _seedBaseline();
    _titleFilled = _cur.title.trim().isNotEmpty;
    for (final c in _controllers) {
      c.addListener(_onFieldChanged);
    }
    _lyricSummary = _summarize(
        _direct.index.lyricsOf(_cur.sourceKey, _cur.sourceRef));
  }

  @override
  void dispose() {
    _direct.removeListener(_onDirectChanged);
    for (final c in _controllers) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    super.dispose();
  }

  List<TextEditingController> get _controllers =>
      [_title, _artist, _albumArtist, _album, _year];

  /// 基线取「当前控件值」：初始化与保存成功后调用。
  void _seedBaseline() {
    for (final c in _controllers) {
      _baseline[c] = c.text.trim();
    }
  }

  bool get _canSave => _titleFilled;

  /// 字段语义：null=未改动不写；''=清空为未知；其余=新值。
  static String? _delta(String input, String? current) {
    final v = input.trim();
    if (v == (current ?? '')) return null;
    return v.isEmpty ? '' : v;
  }

  static String _summarize(String? lyrics) {
    if (lyrics == null || lyrics.trim().isEmpty) return '无';
    final lines =
        lyrics.split(RegExp(r'\r?\n')).where((e) => e.trim().isNotEmpty);
    if (!lyrics.contains('[')) return '纯文本';
    return '${lines.length} 行';
  }

  void _onFieldChanged() {
    final dirty = _controllers.any((c) => c.text.trim() != _baseline[c]);
    final filled = _title.text.trim().isNotEmpty;
    if (dirty != _dirty || filled != _titleFilled) {
      setState(() {
        _dirty = dirty;
        _titleFilled = filled;
      });
    }
  }

  /// 元数据版本变化（在线回填/嵌入/子窗口编辑/后台补读）→ 自动回填本窗。
  void _onDirectChanged() {
    if (!mounted) return;
    final v = _direct.metaVersion;
    if (v == _seenMetaVersion) return;
    _seenMetaVersion = v;
    _refreshFromIndex();
  }

  /// 用索引最新行回填：用户手改过的字段保留，未手改字段跟随最新行。
  void _refreshFromIndex() {
    final fresh =
        _direct.index.songByRef(widget.song.sourceKey, widget.song.sourceRef);
    // 服务端歌无 idx_songs 行时 songByRef 为空：保留本窗现状。
    final f = fresh ?? widget.song;
    void refill(TextEditingController c, String? now) {
      final v = now ?? '';
      if (c.text.trim() != _baseline[c]) return;
      _baseline[c] = v.trim();
      if (c.text != v) c.text = v;
    }

    refill(_title, f.title);
    refill(_artist, f.artist);
    refill(_albumArtist, f.albumArtist);
    refill(_album, f.albumName);
    refill(_year, f.year == null ? '' : '${f.year}');
    setState(() {
      _cur = f;
      _lyricSummary =
          _summarize(_direct.index.lyricsOf(f.sourceKey, f.sourceRef));
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_canSave) {
      AppToast.error(StateError('标题不能为空'));
      return;
    }
    final base = _cur;
    // 年份：null 且不清=不修改；数字=新值；清空（原有值→留空）=clearYear。
    final yearInput = _year.text.trim();
    final yearOrig = base.year;
    int? year;
    var clearYear = false;
    if (yearInput != (yearOrig == null ? '' : '$yearOrig')) {
      if (yearInput.isEmpty) {
        if (yearOrig != null) clearYear = true;
      } else {
        year = int.tryParse(yearInput);
      }
    }

    setState(() => _saving = true);
    try {
      final direct = context.read<DirectSourceManager>();
      final updated = await direct.updateSongMeta(
        base,
        title: _delta(_title.text, base.title),
        artist: _delta(_artist.text, base.artist),
        albumArtist: _delta(_albumArtist.text, base.albumArtist),
        album: _delta(_album.text, base.albumName),
        year: year,
        clearYear: clearYear,
      );
      if (!mounted) return;
      if (updated != null) {
        context.read<PlayerProvider>().refreshSongMeta(updated);
        _cur = updated;
        _seedBaseline();
        setState(() {
          _dirty = false;
          _titleFilled = updated.title.trim().isNotEmpty;
          _editingField = null;
        });
      }
      // 内嵌口径：仅本窗“保存”按钮触发；在线获取/封面/歌词子窗只存缓存。
      final embed = await embedAfterSaveIfEnabled(context, _cur);
      if (!mounted) return;
      Navigator.of(context).pop();
      final label = base.isDirect
          ? '已保存歌曲信息（扫描不再覆盖）'
          : '已保存歌曲信息（本地覆盖）';
      AppToast.show(
        switch (embed?.status) {
          EmbedOutcomeStatus.embedded => '$label，并已将歌词/封面内嵌到歌曲文件',
          EmbedOutcomeStatus.cancelled => '$label，嵌入已取消（仅应用缓存）',
          EmbedOutcomeStatus.failed => '$label，未嵌入：${embed?.detail}',
          EmbedOutcomeStatus.skipped => '$label，未嵌入：${embed?.detail}',
          null => label,
        },
        isError: false,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 统一关闭通道：有未保存修改时二次确认（[PopScope] 与取消键共用）。
  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('关闭后当前修改不会保留。'),
        actions: appDialogActions(
          c,
          cancelLabel: '继续编辑',
          confirmLabel: '放弃',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  /// 打开在线获取（手动）：保存后经 metaVersion 监听自动回填本窗。
  Future<void> _openOnline() async {
    await showDialog<void>(
      context: context,
      builder: (_) => OnlineMetaDialog(song: _cur),
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
      builder: (_) => EmbedProgressDialog(song: _cur),
    );
    if (!mounted || result?.status != EmbedOutcomeStatus.embedded) return;
    _refreshFromIndex();
  }

  Future<void> _openCover() async {
    await showDialog<void>(
      context: context,
      builder: (_) => CoverEditWindow(song: _cur),
    );
    if (!mounted) return;
    _refreshFromIndex();
  }

  Future<void> _openLyrics() async {
    await showDialog<void>(
      context: context,
      builder: (_) => LyricsEditWindow(song: _cur),
    );
    if (!mounted) return;
    _refreshFromIndex();
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final cs = Theme.of(context).colorScheme;

    final states = <String>[];
    if (song.isDirect) {
      if (direct.weight.isFavorite(song)) states.add('喜欢');
      if (direct.weight.isDisliked(song)) states.add('不喜欢');
    }

    final unread = song.metaUnread;
    final displayPath = direct.sourceByKey(song.sourceKey)?.displayPath(song) ??
        decodeUrlForDisplay(song.sourceUrl ?? song.sourceRef);
    final playSec = direct.weight.playSecOf(song);

    // 嵌入入口可见性（同步判定）：直连 + 源可写才显示；内容有无在进度窗内再查。
    var canEmbed = false;
    try {
      final src = direct.sourceByKey(song.sourceKey);
      canEmbed = song.isDirect && src != null && src.supportsWrite;
    } catch (_) {
      canEmbed = false;
    }

    final audio = <Widget>[
      _ro('时长', formatDuration(song.duration, empty: '—'), unread: unread),
      if (SongRowView.formatTextOf(song) != null)
        _ro('格式', SongRowView.formatTextOf(song)!),
      if (unread || SongRowView.bitrateTextOf(song) != null)
        _ro('码率',
            unread ? Song.unreadLabel : SongRowView.bitrateTextOf(song)!,
            unread: unread),
      if (SongRowView.sizeTextOf(song) != null)
        _ro('大小', SongRowView.sizeTextOf(song)!),
    ];

    final stats = <Widget>[
      if (song.isDirect)
        _ro('权重', direct.weight.effectiveFactorOf(song).toStringAsFixed(1)),
      _ro('播放次数', playCountLabel(playSec, song.duration)),
      _ro('播放时长', playSecLabel(playSec)),
      _ro('中位进度',
          formatMedianProgress(direct.weight.medianProgressPercentOf(song))),
    ];

    final source = <Widget>[
      _ro('播放源', '${song.source}（${song.sourceKey}）'),
      _ro('路径', displayPath, mono: true),
    ];

    final unsaved = _dirty || _saving;

    return PopScope(
      canPop: !unsaved,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _requestClose();
      },
      child: AlertDialog(
        title: Text(unsaved ? '歌曲信息 •未保存' : '歌曲信息'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CoverHead(
                  song: song,
                  states: states,
                  cs: cs,
                  onTap: _openCover,
                ),
                _section(context, '基本信息', _basicTiles(), first: true),
                _lyricsSection(context),
                _section(context, '音频信息', audio),
                _section(context, '播放统计', stats),
                _section(context, '来源', source),
                _actionRow(context, canEmbed),
              ],
            ),
          ),
        ),
        actions: unsaved
            ? appDialogActions(
                context,
                cancelLabel: '取消',
                confirmLabel: _saving ? '保存中…' : '保存',
                cancelEnabled: !_saving,
                confirmEnabled: !_saving && _canSave,
                onCancel: _requestClose,
                onConfirm: _save,
              )
            : [appDialogCloseAction(context)],
      ),
    );
  }

  /// 基本信息栏：五个字段始终可就地编辑（未读取时输入框为空，可先手填）；
  /// 流派只读，未读取完成前不展示。
  List<Widget> _basicTiles() {
    final genre = song.genre;
    final unread = song.metaUnread;
    return [
      _edit('标题', _title, hint: '必填'),
      _edit('歌手', _artist, unread: unread),
      _edit('专辑', _album, unread: unread),
      _edit('专辑歌手', _albumArtist, unread: unread),
      if (!unread && genre != null && genre.isNotEmpty)
        _ro('流派', zhDisplay(genre)),
      _edit('年份', _year, digitsOnly: true, unread: unread),
    ];
  }

  Widget _edit(
    String label,
    TextEditingController c, {
    bool digitsOnly = false,
    String hint = '留空为未知',
    bool unread = false,
  }) {
    return _EditableFieldTile(
      label: label,
      controller: c,
      editing: _editingField == label,
      digitsOnly: digitsOnly,
      hint: hint,
      unread: unread,
      onStartEdit: () => setState(() => _editingField = label),
      onEndEdit: () => setState(() => _editingField = null),
      onCopy: () => _copy(context, c.text),
    );
  }

  Widget _ro(String label, String value, {bool unread = false, bool mono = false}) {
    final f = _Field(label, value, unread: unread, mono: mono);
    return _FieldTile(
      field: f,
      selected: _selected == f.key,
      onTap: () =>
          setState(() => _selected = _selected == f.key ? null : f.key),
      onCopy: () => _copy(context, value),
    );
  }

  Widget _section(
    BuildContext context,
    String label,
    List<Widget> children, {
    bool first = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: first ? 4 : 14, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(context, label, cs),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: children,
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(
    BuildContext context,
    String label,
    ColorScheme cs,
  ) {
    return Padding(
      // 歌词栏的标题与入口行之间留 8，与字段区一致。
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: cs.onSurface.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  Widget _lyricsSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final summary = _lyricSummary == '无'
        ? '无（点击设置）'
        : '$_lyricSummary（点击查看/编辑）';
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(context, '歌词', cs),
          InkWell(
            onTap: _openLyrics,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                children: [
                  Icon(Icons.lyrics_outlined,
                      size: 16, color: cs.onSurface.withValues(alpha: 0.55)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right,
                      size: 18, color: cs.onSurface.withValues(alpha: 0.35)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(BuildContext context, bool canEmbed) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: _saving ? null : _openOnline,
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: const Text('在线获取'),
            ),
            if (canEmbed)
              TextButton.icon(
                onPressed: _saving ? null : _openEmbed,
                icon: const Icon(Icons.file_upload_outlined, size: 18),
                label: const Text('嵌入文件'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      if (context.mounted) AppToast.error(e, '复制失败');
      return;
    }
    if (context.mounted) AppToast.show('已复制', isError: false);
  }
}

/// 一条待展示的字段。
class _Field {
  final String label;
  final String value;

  /// 等宽字体（路径）。
  final bool mono;

  /// 该值仍是「待读取」占位。
  final bool unread;

  const _Field(this.label, this.value, {this.mono = false, this.unread = false});

  /// 字段身份：标签+值共同决定，供展开态与动画 key 使用。
  String get key => '$label\u0000$value';
}

/// 封面区：置顶居中、随窗口放大；喜欢/不喜欢作为角标；点击进封面子窗。
class _CoverHead extends StatelessWidget {
  final Song song;
  final List<String> states;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _CoverHead({
    required this.song,
    required this.states,
    required this.cs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final path = song.coverPath;
    final size = (MediaQuery.sizeOf(context).width * 0.34).clamp(116.0, 200.0);
    final showCover = path != null && path.isNotEmpty;

    Widget image;
    if (showCover) {
      final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
      image = Image.file(
        File(coverDisplayPath(path)),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: px,
        cacheHeight: px,
        errorBuilder: (_, __, ___) => _placeholder(size),
      );
    } else {
      image = _placeholder(size);
    }

    final cover = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: cs.primary.withValues(alpha: 0.10),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: image,
            ),
          ),
        ),
        if (states.isNotEmpty)
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              children: [
                if (states.contains('喜欢'))
                  const Icon(Icons.favorite, size: 16, color: Colors.pink),
                if (states.contains('喜欢') && states.contains('不喜欢'))
                  const SizedBox(width: 4),
                if (states.contains('不喜欢'))
                  const Icon(Icons.thumb_down, size: 16, color: Colors.orange),
              ],
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Center(
        child: Tooltip(
          message: '查看/更换封面',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: SizedBox(width: size, height: size, child: cover),
            ),
          ),
        ),
      ),
    );
  }

  /// 无封面占位：未读取元数据时提示「待读取」，否则是音符图标。
  Widget _placeholder(double size) {
    final unread = song.metaUnread;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            unread ? Icons.image_not_supported_outlined : Icons.music_note,
            size: size * 0.30,
            color: cs.primary.withValues(alpha: 0.5),
          ),
          if (unread) ...[
            SizedBox(height: size * 0.05),
            Text(
              Song.unreadLabel,
              style: TextStyle(
                fontSize: size * 0.08,
                color: cs.primary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 可编辑字段块：查看态与 [_FieldTile] 完全一致，点击就地变圆角输入框；
/// 回车/点别处/Esc/失焦都收起，复原为查看态。输入框读写**原文**，
/// 展示态才做简繁转换。
class _EditableFieldTile extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  final bool editing;
  final bool digitsOnly;
  final String hint;

  /// 该歌元数据尚未读取：空值展示为「待读取」而非「—」。
  final bool unread;
  final VoidCallback onStartEdit;
  final VoidCallback onEndEdit;
  final VoidCallback onCopy;

  const _EditableFieldTile({
    required this.label,
    required this.controller,
    required this.editing,
    required this.hint,
    required this.onStartEdit,
    required this.onEndEdit,
    required this.onCopy,
    this.digitsOnly = false,
    this.unread = false,
  });

  @override
  State<_EditableFieldTile> createState() => _EditableFieldTileState();
}

class _EditableFieldTileState extends State<_EditableFieldTile> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 失焦即收起：回车/点别处/Esc 之外的路径（Tab、窗口切走、程序化
    // unfocus）也要复原成查看态，不能让输入框一直挂着。
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && widget.editing) widget.onEndEdit();
  }

  @override
  void didUpdateWidget(covariant _EditableFieldTile old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focus.canRequestFocus) _focus.requestFocus();
      });
    }
    if (!widget.editing && old.editing) _focus.unfocus();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!widget.editing) {
      final raw = widget.controller.text.trim();
      return _FieldTile(
        field: _Field(
          widget.label,
          raw.isEmpty ? (widget.unread ? Song.unreadLabel : '—') : zhDisplay(raw),
          unread: raw.isEmpty && widget.unread,
        ),
        selected: false,
        onTap: widget.onStartEdit,
        onCopy: widget.onCopy,
      );
    }

    return ConstrainedBox(
      // Wrap 内必须有明确宽度区间，否则输入框会塌成一条缝。
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 380),
      child: Padding(
        // 与查看态字段块同一外框（6/5），切换时不跳位。
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  letterSpacing: 0.3,
                  color: cs.primary.withValues(alpha: 0.8),
                ),
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.text,
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    widget.onEndEdit();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: cs.onSurface,
                  ),
                  cursorColor: cs.primary,
                  decoration: InputDecoration(
                    isDense: true,
                    // 只描边、不填充：字段区保持平面，圆角与全 App 输入框一致。
                    filled: false,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kButtonRadius),
                      borderSide: BorderSide(color: cs.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kButtonRadius),
                      borderSide: BorderSide(color: cs.outlineVariant),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kButtonRadius),
                      borderSide: BorderSide(color: cs.primary, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    hintText: widget.hint,
                    hintStyle: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: cs.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                  inputFormatters: widget.digitsOnly
                      ? [FilteringTextInputFormatter.digitsOnly]
                      : null,
                  onSubmitted: (_) => widget.onEndEdit(),
                  onTapOutside: (_) => widget.onEndEdit(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 字段块：小标签在上、值在下；按内容宽度排布，值只换行、不截断。
///
/// 无填充底色；点击/悬停时底部浮现 3px 圆角强调色下划线（内容页 tab 选中态
/// 口径），选中后保持下划线、文字与下划线同色，再次点击取消。
/// 仅路径这类可能极长的值默认两行，选中后展开全文。
class _FieldTile extends StatefulWidget {
  final _Field field;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;

  const _FieldTile({
    required this.field,
    required this.selected,
    this.onTap,
    this.onCopy,
  });

  @override
  State<_FieldTile> createState() => _FieldTileState();
}

class _FieldTileState extends State<_FieldTile> {
  /// 路径折叠行数；其余字段始终完整显示。
  static const int _collapsedLines = 2;

  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = widget.field;
    final active = widget.selected;
    final showBar = _hovered || _focused || active;

    final valueColor = f.unread
        ? cs.onSurface.withValues(alpha: 0.45)
        : (active ? cs.primary : cs.onSurface);
    final labelColor = active
        ? cs.primary.withValues(alpha: 0.8)
        : cs.onSurface.withValues(alpha: 0.45);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onCopy,
        onFocusChange: (v) => setState(() => _focused = v),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      f.label,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.4,
                        letterSpacing: 0.3,
                        color: labelColor,
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width - 92,
                    ),
                    child: Text(
                      f.unread ? Song.unreadLabel : f.value,
                      // 只折叠路径：基本信息/音频/统计的值必须完整可见。
                      maxLines: f.mono && !active ? _collapsedLines : null,
                      overflow: f.mono && !active
                          ? TextOverflow.ellipsis
                          : TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: valueColor,
                        fontFamily: f.mono ? 'monospace' : null,
                      ),
                    ),
                  ),
                ],
              ),
              // 选中下划线：与文字同色、宽度贴合字段内容，悬停/选中淡入。
              Positioned(
                left: 0,
                right: 0,
                bottom: -5,
                child: AnimatedOpacity(
                  opacity: showBar ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

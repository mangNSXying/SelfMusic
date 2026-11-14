import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../utils/cover_thumb.dart';
import '../utils/duration_format.dart';
import '../utils/play_progress.dart';
import '../utils/play_stats.dart';
import '../utils/url_display.dart';
import '../utils/zh_variant.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'song_row_view.dart';

/// 歌曲信息弹窗：封面居中 + 基本信息 / 音频信息 / 播放统计 / 来源 四栏。
///
/// 播放页封面「更多」与歌曲列表行三点菜单共用。
///
/// 布局口径：
/// - 封面置顶居中，随窗口宽度自适应放大，不再与标题挤在一行；
/// - 基本信息是**内容宽度**的字段块（`Wrap` 排列，同添加播放源的单选组），
///   无填充底色；长标题/多歌手整段折行、不省略号截断；
/// - 点击字段块浮现底部强调色下划线并保持选中（内容页 tab 选中态口径），
///   长按复制完整值；路径默认两行、选中后展开全文。
class SongInfoDialog extends StatefulWidget {
  final Song song;
  const SongInfoDialog({super.key, required this.song});

  @override
  State<SongInfoDialog> createState() => _SongInfoDialogState();
}

class _SongInfoDialogState extends State<SongInfoDialog> {
  /// 当前选中的字段键（同一时刻只有一个，与 tab 单选语义一致）。
  String? _selected;

  Song get song => widget.song;

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final cs = Theme.of(context).colorScheme;

    final states = <String>[];
    if (song.isDirect) {
      if (direct.weight.isFavorite(song)) states.add('喜欢');
      if (direct.weight.isDisliked(song)) states.add('不喜欢');
    }

    // 元数据字段：未读取 → 标注「待读取」；已读取且无值 → 留白（—）。
    String? optField(String? v) => song.metaDisplay(v);
    final unread = song.metaUnread;

    // 路径：优先由对应直连源解析真实可读路径（本地绝对路径/WebDAV URL/UNC），
    // 源不在本机时回落到持久化完整 URL 或源内引用；URL 百分号编码展示时解码。
    final displayPath = direct.sourceByKey(song.sourceKey)?.displayPath(song) ??
        decodeUrlForDisplay(song.sourceUrl ?? song.sourceRef);

    // 播放统计：累计秒数→时长文案＋派生次数（play_stats 口径）。
    final playSec = direct.weight.playSecOf(song);

    final basic = <_Field>[
      _Field('标题', zhDisplay(song.title)),
      _Field('歌手', _dash(zhDisplay(optField(song.artist) ?? '—')), unread: unread),
      _Field('专辑', _dash(zhDisplay(optField(song.albumName) ?? '—')), unread: unread),
      _Field('专辑歌手', _dash(zhDisplay(optField(song.albumArtist) ?? '—')),
          unread: unread),
      if (unread || (song.genre != null && song.genre!.isNotEmpty))
        _Field('流派', unread ? Song.unreadLabel : zhDisplay(song.genre!),
            unread: unread),
      if (unread || song.year != null)
        _Field('年份', unread ? Song.unreadLabel : '${song.year}', unread: unread),
    ];

    final audio = <_Field>[
      _Field('时长',
          unread ? Song.unreadLabel : formatDuration(song.duration, empty: '—'),
          unread: unread),
      if (SongRowView.formatTextOf(song) != null)
        _Field('格式', SongRowView.formatTextOf(song)!),
      if (unread || SongRowView.bitrateTextOf(song) != null)
        _Field('码率', unread ? Song.unreadLabel : SongRowView.bitrateTextOf(song)!,
            unread: unread),
      if (SongRowView.sizeTextOf(song) != null)
        _Field('大小', SongRowView.sizeTextOf(song)!),
    ];

    final stats = <_Field>[
      if (song.isDirect)
        _Field('权重', direct.weight.effectiveFactorOf(song).toStringAsFixed(1)),
      _Field('播放次数', playCountLabel(playSec, song.duration)),
      _Field('播放时长', playSecLabel(playSec)),
      _Field('中位进度',
          formatMedianProgress(direct.weight.medianProgressPercentOf(song))),
    ];

    final source = <_Field>[
      _Field('播放源', '${song.source}（${song.sourceKey}）'),
      _Field('路径', displayPath, mono: true),
    ];

    return AlertDialog(
      title: const Text('歌曲信息'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CoverHead(song: song, states: states, cs: cs),
              _section(context, '基本信息', basic, first: true),
              _section(context, '音频信息', audio),
              _section(context, '播放统计', stats),
              _section(context, '来源', source),
            ],
          ),
        ),
      ),
      actions: [appDialogCloseAction(context)],
    );
  }

  static String _dash(String v) => v.trim().isEmpty ? '—' : v;

  Widget _section(
    BuildContext context,
    String label,
    List<_Field> fields, {
    bool first = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: first ? 4 : 14, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
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
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              for (final f in fields)
                _FieldTile(
                  field: f,
                  selected: _selected == f.key,
                  onTap: () =>
                      setState(() => _selected = _selected == f.key ? null : f.key),
                  onCopy: () => _copy(context, f.value),
                ),
            ],
          ),
        ],
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

/// 封面区：置顶居中、随窗口放大；喜欢/不喜欢作为角标。
class _CoverHead extends StatelessWidget {
  final Song song;
  final List<String> states;
  final ColorScheme cs;

  const _CoverHead({
    required this.song,
    required this.states,
    required this.cs,
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

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
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

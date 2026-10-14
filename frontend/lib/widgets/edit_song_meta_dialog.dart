import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import 'app_toast.dart';
import 'online_meta_dialog.dart';

/// 修改歌曲元数据弹窗（全源）：标题/歌手/专辑可编辑＋在线获取入口。
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

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.song.title);
    _artist = TextEditingController(text: widget.song.artist ?? '');
    _albumArtist = TextEditingController(text: widget.song.albumArtist ?? '');
    _album = TextEditingController(text: widget.song.albumName ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _albumArtist.dispose();
    _album.dispose();
    super.dispose();
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

    final direct = context.read<DirectSourceManager>();
    final updated = await direct.updateSongMeta(
      widget.song,
      title: delta(title, widget.song.title),
      artist: delta(_artist.text, widget.song.artist),
      albumArtist: delta(_albumArtist.text, widget.song.albumArtist),
      album: delta(_album.text, widget.song.albumName),
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改歌曲元数据'),
      content: SizedBox(
        width: 340,
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
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openOnline,
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('在线获取歌词/封面…'),
              ),
            ),
          ],
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

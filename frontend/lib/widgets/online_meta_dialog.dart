import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../services/online_meta/online_meta_models.dart';
import '../services/online_meta/online_meta_service.dart';
import '../utils/lrc_parser.dart';
import 'app_toast.dart';

/// 单曲在线获取（纯前端）：LRCLIB 歌词 + MB→CAA 封面 + 标签回填。
///
/// 对标 MusicPlayer2 `LyricDownloadDlg / CoverDownloadDlg / GetTagOnlineDlg`
/// 的手动路径：关键词可改→重搜→最佳匹配高亮→预览→保存/关联。
/// 保存口径遵循设置 `online_meta_save_mode`（默认仅应用缓存）。
class OnlineMetaDialog extends StatefulWidget {
  final Song song;

  /// 初始页：0=歌词，1=封面，2=标签。
  final int initialTab;
  const OnlineMetaDialog({super.key, required this.song, this.initialTab = 0});

  @override
  State<OnlineMetaDialog> createState() => _OnlineMetaDialogState();
}

class _OnlineMetaDialogState extends State<OnlineMetaDialog>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _album;
  late final TabController _tabs;
  late OnlineMetaService _svc;

  bool _lyricSearching = false;
  String _lyricError = '';
  List<OnlineLyricCandidate> _lyrics = const [];
  int _lyricSel = 0;
  bool _lyricSaving = false;

  /// QQ/网易候选正文懒取中（LRCLIB 搜索自带正文，不用此标记）。
  bool _lyricLoading = false;

  bool _coverSearching = false;
  String _coverError = '';
  List<MbRecordingCandidate> _recs = const [];
  int _recSel = 0;
  Uint8List? _coverBytes;
  String _coverLabel = '';
  bool _coverLoadingBytes = false;
  bool _coverSaving = false;

  /// QQ/网易封面页的曲目候选（与 MB 录音候选二选一展示）。
  List<OnlineLyricCandidate> _trackCands = const [];
  int _trackSel = 0;
  Uint8List? _trackCoverBytes;
  String _trackCoverLabel = '';
  bool _trackCoverLoading = false;

  bool _tagSaving = false;

  OnlineMetaLyricSource get _lyricSource =>
      context.read<DirectSourceManager>().settings.onlineMetaLyricSource;
  OnlineMetaCoverSource get _coverSource =>
      context.read<DirectSourceManager>().settings.onlineMetaCoverSource;
  bool get _coverIsMb =>
      _coverSource == OnlineMetaCoverSource.mbCaa;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.song.title);
    _artist = TextEditingController(text: widget.song.artist ?? '');
    _album = TextEditingController(text: widget.song.albumName ?? '');
    _tabs = TabController(
        length: 3,
        vsync: this,
        initialIndex: widget.initialTab.clamp(0, 2));
    final direct = context.read<DirectSourceManager>();
    _svc = OnlineMetaService(
      index: direct.index,
      settings: direct.settings,
    );
    // 打开即搜一次歌词（最佳匹配直接高亮）；封面页初始时同步搜封面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchLyrics();
      if (widget.initialTab == 1) _searchCovers();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _tabs.dispose();
    super.dispose();
  }

  String get _qTitle => _title.text.trim();
  String get _qArtist => _artist.text.trim();
  String get _qAlbum => _album.text.trim();

  Future<void> _searchLyrics() async {
    if (_lyricSearching) return;
    setState(() {
      _lyricSearching = true;
      _lyricError = '';
    });
    try {
      final list = await _svc.searchLyrics(
        widget.song,
        titleOverride: _qTitle,
        artistOverride: _qArtist,
        albumOverride: _qAlbum,
      );
      if (!mounted) return;
      setState(() {
        _lyrics = list;
        _lyricSel = 0;
        if (list.isEmpty) {
          _lyricError =
              '无结果：${_lyricSource.label}找不到（换关键词重搜，或去设置换源）';
        }
      });
      // QQ/网易搜索不带正文：最佳匹配直接懒取，预览立即可见。
      if (list.isNotEmpty && !list.first.hasContent) {
        await _ensureLyric(0);
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _lyricError = '网络失败：${_dioMsg(e)}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _lyricError = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _lyricSearching = false);
    }
  }

  /// 懒取第 [i] 个歌词候选的正文（已有正文直接返回）。
  Future<void> _ensureLyric(int i) async {
    if (_lyrics.isEmpty || _lyricLoading) return;
    final c = _lyrics[i.clamp(0, _lyrics.length - 1)];
    if (c.hasContent) return;
    setState(() => _lyricLoading = true);
    try {
      final full = await _svc.ensureLyrics(c);
      if (!mounted) return;
      setState(() {
        _lyrics = [
          for (var j = 0; j < _lyrics.length; j++)
            j == i.clamp(0, _lyrics.length - 1) ? full : _lyrics[j]
        ];
        if (!full.hasContent) {
          _lyricError = '该候选暂无歌词正文（换一个候选或换源）';
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _lyricError = '取词失败：${_dioMsg(e)}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _lyricError = '取词失败：$e');
    } finally {
      if (mounted) setState(() => _lyricLoading = false);
    }
  }

  Future<void> _searchCovers() async {
    if (_coverIsMb) {
      await _searchMbCovers();
    } else {
      await _searchTrackCovers();
    }
  }

  Future<void> _searchMbCovers() async {
    if (_coverSearching) return;
    setState(() {
      _coverSearching = true;
      _coverError = '';
      _coverBytes = null;
      _coverLabel = '';
    });
    try {
      final list = await _svc.searchRecordings(
        widget.song,
        titleOverride: _qTitle,
        artistOverride: _qArtist,
      );
      if (!mounted) return;
      setState(() {
        _recs = list;
        _recSel = 0;
        if (list.isEmpty) {
          _coverError = '无结果：MusicBrainz 找不到录音（换关键词重搜）';
        } else if (list.every((r) =>
            r.releaseId == null || r.releaseId!.isEmpty)) {
          _coverError = '找到录音但均无 release（CAA 需 release MBID，无图可下）';
        }
      });
      if (list.isNotEmpty) await _loadCoverBytes();
    } on DioException catch (e) {
      if (!mounted) return;
      // MB 限流 429/503：退避后重试由用户手动点搜索。
      setState(() => _coverError = '网络失败：${_dioMsg(e)}（MB 限流 1次/秒，稍后重搜）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _coverError = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _coverSearching = false);
    }
  }

  Future<void> _loadCoverBytes() async {
    if (_recs.isEmpty) return;
    final rec = _recs[_recSel.clamp(0, _recs.length - 1)];
    if (rec.releaseId == null || rec.releaseId!.isEmpty) {
      setState(() {
        _coverBytes = null;
        _coverLabel = '';
        _coverError = '该录音无 release（换一个候选）';
      });
      return;
    }
    setState(() {
      _coverLoadingBytes = true;
      _coverError = '';
      _coverBytes = null;
    });
    try {
      final c = await _svc.fetchCover(rec);
      if (!mounted) return;
      setState(() {
        _coverLoadingBytes = false;
        if (c == null) {
          _coverError = '该 release 无封面（CAA 404 常见，换一个候选）';
        } else {
          _coverBytes = Uint8List.fromList(c.bytes);
          _coverLabel = c.label;
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _coverLoadingBytes = false;
        _coverError = '封面下载失败：${_dioMsg(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _coverLoadingBytes = false;
        _coverError = '封面下载失败：$e';
      });
    }
  }

  /// QQ/网易封面页的曲目搜索（与歌词页同源候选，选中即取图）。
  Future<void> _searchTrackCovers() async {
    if (_coverSearching) return;
    setState(() {
      _coverSearching = true;
      _coverError = '';
      _trackCands = const [];
      _trackSel = 0;
      _trackCoverBytes = null;
      _trackCoverLabel = '';
    });
    try {
      final list = await _svc.searchCoverTracks(
        widget.song,
        titleOverride: _qTitle,
        artistOverride: _qArtist,
        albumOverride: _qAlbum,
      );
      if (!mounted) return;
      setState(() {
        _trackCands = list;
        _trackSel = 0;
        if (list.isEmpty) {
          _coverError =
              '无结果：${_coverSource.label}找不到（换关键词重搜，或去设置换源）';
        }
      });
      if (list.isNotEmpty) await _loadTrackCoverBytes();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _coverError = '网络失败：${_dioMsg(e)}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _coverError = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _coverSearching = false);
    }
  }

  Future<void> _loadTrackCoverBytes() async {
    if (_trackCands.isEmpty) return;
    final cand = _trackCands[_trackSel.clamp(0, _trackCands.length - 1)];
    setState(() {
      _trackCoverLoading = true;
      _coverError = '';
      _trackCoverBytes = null;
      _trackCoverLabel = '';
    });
    try {
      final c = await _svc.fetchTrackCover(cand);
      if (!mounted) return;
      setState(() {
        _trackCoverLoading = false;
        if (c == null) {
          _coverError = '该候选无封面（换一个候选或换源）';
        } else {
          _trackCoverBytes = Uint8List.fromList(c.bytes);
          _trackCoverLabel = c.label;
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _trackCoverLoading = false;
        _coverError = '封面下载失败：${_dioMsg(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _trackCoverLoading = false;
        _coverError = '封面下载失败：$e';
      });
    }
  }

  Future<void> _saveLyrics() async {
    if (_lyrics.isEmpty || _lyricSaving || _lyricLoading) return;
    var c = _lyrics[_lyricSel.clamp(0, _lyrics.length - 1)];
    if (!c.hasContent) {
      await _ensureLyric(_lyricSel);
      if (!mounted) return;
      c = _lyrics[_lyricSel.clamp(0, _lyrics.length - 1)];
    }
    if (!c.hasContent) {
      AppToast.show('该候选无歌词正文', isError: true);
      return;
    }
    setState(() => _lyricSaving = true);
    try {
      final direct = context.read<DirectSourceManager>();
      final src = direct.sourceByKey(widget.song.sourceKey);
      final content = _withLyricTags(c.saveContent);
      final r = await _svc.applyLyrics(widget.song, content, src: src);
      if (!mounted) return;
      context.read<PlayerProvider>().reloadLyricsIfCurrent(widget.song);
      Navigator.of(context).pop();
      AppToast.show(
        r.sidecarPath != null
            ? '歌词已保存并覆盖 ${r.sidecarPath}（应用缓存同步）'
            : r.sidecarSkipped
                ? '歌词已保存到应用缓存（该源不支持写回，已跳过 sidecar）'
                : '歌词已保存到应用缓存',
        isError: false,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '保存歌词失败');
    } finally {
      if (mounted) setState(() => _lyricSaving = false);
    }
  }

  Future<void> _saveCover() async {
    if (_coverBytes == null || _coverBytes!.isEmpty || _coverSaving) return;
    setState(() => _coverSaving = true);
    try {
      final bytes = _coverBytes!;
      final direct = context.read<DirectSourceManager>();
      final src = direct.sourceByKey(widget.song.sourceKey);
      final r = await _svc.applyCover(widget.song, bytes, src: src);
      if (!mounted) return;
      final updated =
          direct.index.songByRef(widget.song.sourceKey, widget.song.sourceRef);
      if (updated != null) {
        direct.refresh();
        context.read<PlayerProvider>().refreshSongMeta(updated);
      }
      Navigator.of(context).pop();
      AppToast.show(
        r.sidecarPath != null
            ? '封面已保存并覆盖 ${r.sidecarPath}（应用缓存同步）'
            : r.sidecarSkipped
                ? '封面已保存到应用缓存（该源不支持写回，已跳过 cover.jpg）'
                : '封面已保存到应用缓存',
        isError: false,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '保存封面失败');
    } finally {
      if (mounted) setState(() => _coverSaving = false);
    }
  }

  /// 标签回填（只写标题/歌手/专辑）：用当前选中的歌词/录音候选。
  Future<void> _applyTagsFromLyric() async {
    if (_lyrics.isEmpty || _tagSaving) return;
    final c = _lyrics[_lyricSel.clamp(0, _lyrics.length - 1)];
    await _applyTags(title: c.trackName, artist: c.artistName, album: c.albumName);
  }

  Future<void> _applyTagsFromRec() async {
    if (_recs.isEmpty || _tagSaving) return;
    final r = _recs[_recSel.clamp(0, _recs.length - 1)];
    await _applyTags(
      title: r.title,
      artist: r.artist,
      album: r.releaseTitle,
    );
  }

  /// 标签回填：用 QQ/网易曲目候选。
  Future<void> _applyTagsFromTrack() async {
    if (_trackCands.isEmpty || _tagSaving) return;
    final c = _trackCands[_trackSel.clamp(0, _trackCands.length - 1)];
    await _applyTags(
        title: c.trackName, artist: c.artistName, album: c.albumName);
  }

  /// 保存 QQ/网易曲目封面（预览字节 → 应用缓存 + sidecar）。
  Future<void> _saveTrackCover() async {
    if (_trackCoverBytes == null ||
        _trackCoverBytes!.isEmpty ||
        _coverSaving) {
      return;
    }
    setState(() => _coverSaving = true);
    try {
      final bytes = _trackCoverBytes!;
      final direct = context.read<DirectSourceManager>();
      final src = direct.sourceByKey(widget.song.sourceKey);
      final r = await _svc.applyCover(widget.song, bytes, src: src);
      if (!mounted) return;
      final updated =
          direct.index.songByRef(widget.song.sourceKey, widget.song.sourceRef);
      if (updated != null) {
        direct.refresh();
        context.read<PlayerProvider>().refreshSongMeta(updated);
      }
      Navigator.of(context).pop();
      AppToast.show(
        r.sidecarPath != null
            ? '封面已保存并覆盖 ${r.sidecarPath}（应用缓存同步）'
            : r.sidecarSkipped
                ? '封面已保存到应用缓存（该源不支持写回，已跳过 cover.jpg）'
                : '封面已保存到应用缓存',
        isError: false,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '保存封面失败');
    } finally {
      if (mounted) setState(() => _coverSaving = false);
    }
  }

  Future<void> _applyTags({String? title, String? artist, String? album}) async {
    setState(() => _tagSaving = true);
    try {
      String? delta(String? input, String? current) {
        if (input == null) return null;
        final v = input.trim();
        if (v.isEmpty) return null; // 在线值为空不覆盖
        if (v == (current ?? '')) return null;
        return v;
      }

      final updated = await _svc.applyTags(
        widget.song,
        title: delta(title, widget.song.title),
        artist: delta(artist, widget.song.artist),
        album: delta(album, widget.song.albumName),
      );
      if (!mounted) return;
      if (updated != null) {
        context.read<DirectSourceManager>().refresh();
        context.read<PlayerProvider>().refreshSongMeta(updated);
        Navigator.of(context).pop();
        AppToast.show('已回填标题/歌手/专辑（扫描不再覆盖）', isError: false);
      } else {
        AppToast.show('在线值与本地一致，无需回填', isError: false);
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '回填标签失败');
    } finally {
      if (mounted) setState(() => _tagSaving = false);
    }
  }

  /// 对标 MusicPlayer2 `AddLyricTag`：缺 `[ti:/ar:/al:]` 则补。
  String _withLyricTags(String content) {
    final hasTi = RegExp(r'^\[ti:', multiLine: true, caseSensitive: false)
        .hasMatch(content);
    final hasAr = RegExp(r'^\[ar:', multiLine: true, caseSensitive: false)
        .hasMatch(content);
    final hasAl = RegExp(r'^\[al:', multiLine: true, caseSensitive: false)
        .hasMatch(content);
    final buf = StringBuffer();
    if (!hasTi && _qTitle.isNotEmpty) buf.writeln('[ti:$_qTitle]');
    if (!hasAr && _qArtist.isNotEmpty) buf.writeln('[ar:$_qArtist]');
    if (!hasAl && _qAlbum.isNotEmpty) buf.writeln('[al:$_qAlbum]');
    buf.write(content);
    return buf.toString();
  }

  static String _dioMsg(DioException e) {
    final code = e.response?.statusCode;
    if (code != null) return 'HTTP $code';
    return e.message ?? e.type.name;
  }

  @override
  Widget build(BuildContext context) {
    final saveMode = context
        .select<DirectSourceManager, OnlineMetaSaveMode>((d) => d.settings.onlineMetaSaveMode);
    final lyricSource = context.select<DirectSourceManager,
            OnlineMetaLyricSource>(
        (d) => d.settings.onlineMetaLyricSource);
    final coverSource = context.select<DirectSourceManager,
            OnlineMetaCoverSource>(
        (d) => d.settings.onlineMetaCoverSource);
    return AlertDialog(
      title: const Text('在线获取元数据'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: '标题',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _artist,
                    decoration: const InputDecoration(
                      labelText: '歌手',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _album,
                    decoration: const InputDecoration(
                      labelText: '专辑（可空）',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () {
                    if (_tabs.index == 2) {
                      _searchCovers();
                    } else {
                      _searchLyrics();
                      if (_tabs.index == 1) _searchCovers();
                    }
                  },
                  child: const Text('重搜'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '歌词：${lyricSource.label} · 封面：${coverSource.label}（设置可换源，无自动串源） · 保存：${saveMode == OnlineMetaSaveMode.sidecar ? '应用缓存＋写回源目录（同名覆盖）' : '仅应用缓存'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 8),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '歌词'),
                Tab(text: '封面'),
                Tab(text: '标签'),
              ],
              onTap: (i) {
                if (i == 1 &&
                    _recs.isEmpty &&
                    _trackCands.isEmpty &&
                    !_coverSearching) {
                  _searchCovers();
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _lyricTab(),
                  _coverTab(),
                  _tagTab(),
                ],
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
      ],
    );
  }

  Widget _lyricTab() {
    if (_lyricSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_lyricError.isNotEmpty && _lyrics.isEmpty) {
      return Center(
        child: Text(_lyricError, textAlign: TextAlign.center),
      );
    }
    if (_lyrics.isEmpty) {
      return const Center(child: Text('暂无候选，换关键词重搜'));
    }
    final sel = _lyrics[_lyricSel.clamp(0, _lyrics.length - 1)];
    final preview = _lyricLoading
        ? '正文加载中…'
        : sel.hasContent
            ? _lyricPreview(sel.saveContent)
            : '该候选暂无正文（选中后自动加载，仍无请换候选）';
    return Column(
      children: [
        Expanded(
          child: RadioGroup<int>(
            groupValue: _lyricSel,
            onChanged: (v) {
              setState(() => _lyricSel = v ?? 0);
              _ensureLyric(_lyricSel);
            },
            child: ListView.builder(
              itemCount: _lyrics.length,
              itemBuilder: (c, i) {
                final e = _lyrics[i];
                final best = i == 0;
                return RadioListTile<int>(
                  dense: true,
                  value: i,
                  title: Text(
                    '${e.trackName} — ${e.artistName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${e.source} · ${e.albumName.isEmpty ? '未知专辑' : e.albumName}'
                    '${e.durationSec != null ? ' · ${_fmtDur(e.durationSec!)}' : ''}'
                    '${e.hasContent ? (e.syncedLyrics != null && e.syncedLyrics!.contains('[') ? ' · 同步' : ' · 纯文本') : ''}'
                    ' · ${e.matchWeight.toStringAsFixed(2)}${best ? ' · 最佳匹配' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Text(preview,
                style: const TextStyle(fontSize: 12, height: 1.5)),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _tagSaving ? null : _applyTagsFromLyric,
                child: Text(_tagSaving ? '回填中…' : '回填标题/歌手/专辑'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: (_lyricSaving || _lyricLoading) ? null : _saveLyrics,
                child: Text(_lyricSaving
                    ? '保存中…'
                    : _lyricLoading
                        ? '加载中…'
                        : '保存歌词'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _coverTab() {
    if (_coverIsMb) return _mbCoverTab();
    return _trackCoverTab();
  }

  Widget _mbCoverTab() {
    if (_coverSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_recs.isEmpty) {
      return Center(
        child: Text(_coverError.isEmpty ? '切到此页自动搜索' : _coverError,
            textAlign: TextAlign.center),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 120,
          child: RadioGroup<int>(
            groupValue: _recSel,
            onChanged: (v) {
              setState(() => _recSel = v ?? 0);
              _loadCoverBytes();
            },
            child: ListView.builder(
              itemCount: _recs.length,
              itemBuilder: (c, i) {
                final e = _recs[i];
                return RadioListTile<int>(
                  dense: true,
                  value: i,
                  title: Text(
                    '${e.title} — ${e.artist.isEmpty ? '未知歌手' : e.artist}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${e.releaseTitle ?? '无 release'} · ${e.matchWeight.toStringAsFixed(2)}${i == 0 ? ' · 最佳匹配' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: Center(
            child: _coverLoadingBytes
                ? const CircularProgressIndicator()
                : _coverBytes != null
                    ? Image.memory(_coverBytes!, fit: BoxFit.contain)
                    : Text(
                        _coverError.isEmpty ? '无预览' : _coverError,
                        textAlign: TextAlign.center,
                      ),
          ),
        ),
        if (_coverLabel.isNotEmpty)
          Text(_coverLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _tagSaving ? null : _applyTagsFromRec,
                child: Text(_tagSaving ? '回填中…' : '回填标题/歌手/专辑'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: (_coverBytes == null || _coverSaving)
                    ? null
                    : _saveCover,
                child: Text(_coverSaving ? '保存中…' : '保存封面'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// QQ/网易封面页：曲目候选（与歌词页同源）+ 选中即取图预览。
  Widget _trackCoverTab() {
    if (_coverSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_trackCands.isEmpty) {
      return Center(
        child: Text(_coverError.isEmpty ? '切到此页自动搜索' : _coverError,
            textAlign: TextAlign.center),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 120,
          child: RadioGroup<int>(
            groupValue: _trackSel,
            onChanged: (v) {
              setState(() => _trackSel = v ?? 0);
              _loadTrackCoverBytes();
            },
            child: ListView.builder(
              itemCount: _trackCands.length,
              itemBuilder: (c, i) {
                final e = _trackCands[i];
                return RadioListTile<int>(
                  dense: true,
                  value: i,
                  title: Text(
                    '${e.trackName} — ${e.artistName.isEmpty ? '未知歌手' : e.artistName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${e.source} · ${e.albumName.isEmpty ? '未知专辑' : e.albumName}'
                    '${e.durationSec != null ? ' · ${_fmtDur(e.durationSec!)}' : ''}'
                    ' · ${e.matchWeight.toStringAsFixed(2)}${i == 0 ? ' · 最佳匹配' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: Center(
            child: _trackCoverLoading
                ? const CircularProgressIndicator()
                : _trackCoverBytes != null
                    ? Image.memory(_trackCoverBytes!, fit: BoxFit.contain)
                    : Text(
                        _coverError.isEmpty ? '无预览' : _coverError,
                        textAlign: TextAlign.center,
                      ),
          ),
        ),
        if (_trackCoverLabel.isNotEmpty)
          Text(_trackCoverLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _tagSaving ? null : _applyTagsFromTrack,
                child: Text(_tagSaving ? '回填中…' : '回填标题/歌手/专辑'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: (_trackCoverBytes == null || _coverSaving)
                    ? null
                    : _saveTrackCover,
                child: Text(_coverSaving ? '保存中…' : '保存封面'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tagTab() {
    final hasLyric = _lyrics.isNotEmpty;
    final hasRec = _recs.isNotEmpty;
    final hasTrack = _trackCands.isNotEmpty;
    final trackSel = _trackCands.isEmpty
        ? null
        : _trackCands[_trackSel.clamp(0, _trackCands.length - 1)];
    return ListView(
      children: [
        const Text('从在线候选回填标题/歌手/专辑（空值不覆盖本地，扫描不再覆盖已回填行）。'),
        const SizedBox(height: 12),
        ListTile(
          title: const Text('用歌词候选回填'),
          subtitle: Text(hasLyric
              ? '${_lyrics[_lyricSel.clamp(0, _lyrics.length - 1)].trackName} — ${_lyrics[_lyricSel.clamp(0, _lyrics.length - 1)].artistName}'
              : '先在歌词页搜索'),
          trailing: const Icon(Icons.chevron_right),
          enabled: hasLyric && !_tagSaving,
          onTap: hasLyric ? _applyTagsFromLyric : null,
        ),
        if (_coverIsMb)
          ListTile(
            title: const Text('用封面候选（MB录音）回填'),
            subtitle: Text(hasRec
                ? '${_recs[_recSel.clamp(0, _recs.length - 1)].title} — ${_recs[_recSel.clamp(0, _recs.length - 1)].artist}'
                : '先在封面页搜索'),
            trailing: const Icon(Icons.chevron_right),
            enabled: hasRec && !_tagSaving,
            onTap: hasRec ? _applyTagsFromRec : null,
          )
        else
          ListTile(
            title: Text('用封面候选（${_coverSource.label}）回填'),
            subtitle: Text(hasTrack && trackSel != null
                ? '${trackSel.trackName} — ${trackSel.artistName}'
                : '先在封面页搜索'),
            trailing: const Icon(Icons.chevron_right),
            enabled: hasTrack && !_tagSaving,
            onTap: hasTrack ? _applyTagsFromTrack : null,
          ),
        const Divider(),
        const Text('说明：只回填标题/歌手/专辑，不含流派/年份/曲目号；封面/歌词请在前两页单独保存。'),
      ],
    );
  }

  static String _lyricPreview(String content) {
    // 预览：解析后取前 20 行（纯文本直接截断），避免超长对话框卡顿。
    try {
      final p = parseLyrics(content);
      if (p.lines.isNotEmpty) {
        final take = p.lines.take(20).map((e) => e.text).join('\n');
        return p.lines.length > 20 ? '$take\n…' : take;
      }
      final t = (p.plain ?? content).trim();
      if (t.length > 600) return '${t.substring(0, 600)}\n…';
      return t;
    } catch (_) {
      final t = content.trim();
      if (t.length > 600) return '${t.substring(0, 600)}\n…';
      return t;
    }
  }

  static String _fmtDur(double sec) {
    final s = sec.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

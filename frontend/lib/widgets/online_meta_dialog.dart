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
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'online_meta_detail_dialog.dart';

enum _TagSource { lyrics, cover }

/// 单曲在线获取（纯前端）：LRCLIB 歌词 + MB→CAA 封面 + 标签回填。
///
/// 对标 MusicPlayer2 `LyricDownloadDlg / CoverDownloadDlg / GetTagOnlineDlg`
/// 的手动路径：关键词可改→重搜→最佳匹配高亮→预览→保存/关联。
/// 三页统一「点选候选 + 行尾查看 + 底部保存」：歌词/封面保存当前候选，
/// 标签页选回填来源（歌词/封面候选）后由底部保存回填标题/歌手/专辑。
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
  bool _coverSaving = false;

  /// QQ/网易封面页的曲目候选（与 MB 录音候选二选一展示）。
  List<OnlineLyricCandidate> _trackCands = const [];
  int _trackSel = 0;

  /// 封面字节缓存（详情查看/保存共用；新搜索清空，避免二次下载）。
  final Map<String, ({Uint8List bytes, String label})> _coverCache = {};

  /// 标签回填的来源：歌词候选 / 封面候选（具体候选取对应页当前选中项）。
  _TagSource _tagSource = _TagSource.lyrics;

  bool _tagSaving = false;

  /// 当前页签（与 [_tabs] 同步；底部保存按钮按页签切换）。
  late int _tabIndex;

  OnlineMetaLyricSource get _lyricSource =>
      context.read<DirectSourceManager>().settings.onlineMetaLyricSource;
  OnlineMetaCoverSource get _coverSource =>
      context.read<DirectSourceManager>().settings.onlineMetaCoverSource;
  bool get _coverIsMb =>
      _coverSource == OnlineMetaCoverSource.mbCaa;

  bool get _hasLyricCands => _lyrics.isNotEmpty;
  bool get _hasCoverCands =>
      _coverIsMb ? _recs.isNotEmpty : _trackCands.isNotEmpty;

  /// 标签页实际生效的来源：所选来源还没有候选时落到另一来源。
  _TagSource get _activeTagSource {
    if (_tagSource == _TagSource.lyrics && !_hasLyricCands && _hasCoverCands) {
      return _TagSource.cover;
    }
    if (_tagSource == _TagSource.cover && !_hasCoverCands && _hasLyricCands) {
      return _TagSource.lyrics;
    }
    return _tagSource;
  }

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
    _tabIndex = _tabs.index;
    _tabs.addListener(_onTabChanged);
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

  /// 底部保存按钮跟随页签：点按在 onTap 里立即切换，滑动在动画结束后切换。
  void _onTabChanged() {
    if (!mounted || _tabs.indexIsChanging) return;
    if (_tabs.index == _tabIndex) return;
    setState(() => _tabIndex = _tabs.index);
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
      // QQ/网易搜索不带正文：预取最佳匹配正文（列表徽标与保存即用）。
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
      _coverCache.clear();
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

  /// 取选中 MB 录音的封面字节（缓存优先）。无 release/无图 → null 并置
  /// 列表下提示；网络失败抛错（保存流程统一 toast，详情窗自带错误态）。
  Future<({Uint8List bytes, String label})?> _ensureMbCover() async {
    if (_recs.isEmpty) return null;
    final rec = _recs[_recSel.clamp(0, _recs.length - 1)];
    if (rec.releaseId == null || rec.releaseId!.isEmpty) {
      if (mounted) setState(() => _coverError = '该录音无 release（换一个候选）');
      return null;
    }
    final key = _mbCoverKey(rec);
    final hit = _coverCache[key];
    if (hit != null) return hit;
    final c = await _svc.fetchCover(rec);
    if (c == null) {
      if (mounted) {
        setState(() => _coverError = '该 release 无封面（CAA 404 常见，换一个候选）');
      }
      return null;
    }
    final entry = (bytes: Uint8List.fromList(c.bytes), label: c.label);
    _coverCache[key] = entry;
    return entry;
  }

  /// QQ/网易封面页的曲目搜索（与歌词页同源候选，选中即取图）。
  Future<void> _searchTrackCovers() async {
    if (_coverSearching) return;
    setState(() {
      _coverSearching = true;
      _coverError = '';
      _trackCands = const [];
      _trackSel = 0;
      _coverCache.clear();
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

  /// 取选中 QQ/网易曲目候选的封面字节（缓存优先）。无图 → null 并置提示；
  /// 网络失败抛错（保存流程统一 toast，详情窗自带错误态）。
  Future<({Uint8List bytes, String label})?> _ensureTrackCover() async {
    if (_trackCands.isEmpty) return null;
    final cand = _trackCands[_trackSel.clamp(0, _trackCands.length - 1)];
    final key = _trackCoverKey(cand);
    final hit = _coverCache[key];
    if (hit != null) return hit;
    final c = await _svc.fetchTrackCover(cand);
    if (c == null) {
      if (mounted) setState(() => _coverError = '该候选无封面（换一个候选或换源）');
      return null;
    }
    final entry = (bytes: Uint8List.fromList(c.bytes), label: c.label);
    _coverCache[key] = entry;
    return entry;
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
      final player = context.read<PlayerProvider>();
      final src = direct.sourceByKey(widget.song.sourceKey);
      final content = _withLyricTags(c.saveContent);
      final r = await _svc.applyLyrics(widget.song, content, src: src);
      // 先通知再判 mounted：保存后立刻关窗也不能丢掉全局刷新信号。
      direct.notifySongMetaChanged();
      player.reloadLyricsIfCurrent(widget.song);
      if (!mounted) return;
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

  /// 保存封面（MB 录音口径）：取字节（缓存/懒取）→ 应用；保存后留窗。
  Future<void> _saveCover() async {
    if (_recs.isEmpty || _coverSaving) return;
    setState(() {
      _coverSaving = true;
      _coverError = '';
    });
    try {
      final entry = await _ensureMbCover();
      if (!mounted) return;
      if (entry == null) return; // 具体原因已置 _coverError
      await _applyCoverBytes(entry.bytes);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '保存封面失败');
    } finally {
      if (mounted) setState(() => _coverSaving = false);
    }
  }

  /// 标签页底部保存：按当前选中的回填来源取对应页的选中候选。
  Future<void> _saveTags() async {
    if (_tagSaving) return;
    if (_activeTagSource == _TagSource.lyrics) {
      if (!_hasLyricCands) return;
      final c = _lyrics[_lyricSel.clamp(0, _lyrics.length - 1)];
      await _applyTags(
          title: c.trackName, artist: c.artistName, album: c.albumName);
    } else if (_coverIsMb) {
      if (_recs.isEmpty) return;
      final r = _recs[_recSel.clamp(0, _recs.length - 1)];
      await _applyTags(
        title: r.title,
        artist: r.artist,
        album: r.releaseTitle,
      );
    } else {
      if (_trackCands.isEmpty) return;
      final c = _trackCands[_trackSel.clamp(0, _trackCands.length - 1)];
      await _applyTags(
          title: c.trackName, artist: c.artistName, album: c.albumName);
    }
  }

  /// 保存封面（QQ/网易曲目口径）：取字节（缓存/懒取）→ 应用；保存后留窗。
  Future<void> _saveTrackCover() async {
    if (_trackCands.isEmpty || _coverSaving) return;
    setState(() {
      _coverSaving = true;
      _coverError = '';
    });
    try {
      final entry = await _ensureTrackCover();
      if (!mounted) return;
      if (entry == null) return;
      await _applyCoverBytes(entry.bytes);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '保存封面失败');
    } finally {
      if (mounted) setState(() => _coverSaving = false);
    }
  }

  /// 应用封面字节（应用缓存 + sidecar）；成功 toast，失败上抛（留窗）。
  Future<void> _applyCoverBytes(Uint8List bytes) async {
    final direct = context.read<DirectSourceManager>();
    final player = context.read<PlayerProvider>();
    final src = direct.sourceByKey(widget.song.sourceKey);
    final r = await _svc.applyCover(widget.song, bytes, src: src);
    final updated =
        direct.index.songByRef(widget.song.sourceKey, widget.song.sourceRef);
    if (updated != null) {
      // 先通知再判 mounted：保存后立刻关窗也不能丢掉全局刷新信号。
      direct.notifySongMetaChanged();
      player.refreshSongMeta(updated);
    }
    if (!mounted) return;
    AppToast.show(
      r.sidecarPath != null
          ? '封面已保存并覆盖 ${r.sidecarPath}（应用缓存同步）'
          : r.sidecarSkipped
              ? '封面已保存到应用缓存（该源不支持写回，已跳过 cover.jpg）'
              : '封面已保存到应用缓存',
      isError: false,
    );
  }

  Future<void> _applyTags({String? title, String? artist, String? album}) async {
    setState(() => _tagSaving = true);
    final direct = context.read<DirectSourceManager>();
    final player = context.read<PlayerProvider>();
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
      if (updated != null) {
        // 先通知再判 mounted：保存后立刻关窗也不能丢掉全局刷新信号。
        direct.notifySongMetaChanged();
        player.refreshSongMeta(updated);
      }
      if (!mounted) return;
      if (updated != null) {
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
                setState(() => _tabIndex = i);
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
      actions: _bottomActions(),
    );
  }

  /// 底部动作条：关闭 + 当前页签的保存按钮（三页同层级）。
  List<Widget> _bottomActions() {
    final save = switch (_tabIndex.clamp(0, 2)) {
      1 => _coverSaveButton(),
      2 => _tagSaveButton(),
      _ => _lyricSaveButton(),
    };
    return [appDialogCloseAction(context), save];
  }

  Widget _lyricSaveButton() => FilledButton(
        onPressed: (_lyrics.isEmpty || _lyricSaving || _lyricLoading)
            ? null
            : _saveLyrics,
        child: Text(
          _lyricSaving
              ? '保存中…'
              : _lyricLoading
                  ? '加载中…'
                  : '保存歌词',
        ),
      );

  Widget _coverSaveButton() => FilledButton(
        onPressed:
            ((_coverIsMb ? _recs.isEmpty : _trackCands.isEmpty) || _coverSaving)
                ? null
                : (_coverIsMb ? _saveCover : _saveTrackCover),
        child: Text(_coverSaving ? '保存中…' : '保存封面'),
      );

  Widget _tagSaveButton() {
    final hasCands =
        _activeTagSource == _TagSource.lyrics ? _hasLyricCands : _hasCoverCands;
    return FilledButton(
      onPressed: (hasCands && !_tagSaving) ? _saveTags : null,
      child: Text(_tagSaving ? '保存中…' : '保存标签'),
    );
  }

  /// 打开歌词候选详情窗（QQ/网易懒取正文，取到后回填列表）。
  void _openLyricDetail(int i) {
    if (_lyrics.isEmpty) return;
    final idx = i.clamp(0, _lyrics.length - 1);
    final c = _lyrics[idx];
    setState(() => _lyricSel = idx);
    showDialog<void>(
      context: context,
      builder: (_) => LyricDetailDialog(
        candidate: c,
        ensure: (cand) => _svc.ensureLyrics(cand),
        isBest: idx == 0,
        onLoaded: (full) {
          if (!mounted || idx >= _lyrics.length) return;
          setState(() => _lyrics[idx] = full);
        },
      ),
    );
  }

  /// 打开 MB 录音封面详情窗（懒取字节并缓存回主窗）。
  void _openMbCoverDetail(int i) {
    if (_recs.isEmpty) return;
    final idx = i.clamp(0, _recs.length - 1);
    final rec = _recs[idx];
    setState(() => _recSel = idx);
    final key = _mbCoverKey(rec);
    final hit = _coverCache[key];
    showDialog<void>(
      context: context,
      builder: (_) => CoverDetailDialog(
        header:
            '${rec.title} — ${rec.artist.isEmpty ? '未知歌手' : rec.artist}',
        metaLines: [
          '来源 ${OnlineMetaSource.mbCaa}',
          'release ${rec.releaseTitle ?? '无（无图可下）'}',
          '匹配 ${rec.matchWeight.toStringAsFixed(2)}${idx == 0 ? ' · 最佳匹配' : ''}',
        ],
        initialBytes: hit?.bytes,
        initialLabel: hit?.label ?? '',
        load: () async {
          final c = await _svc.fetchCover(rec);
          if (c == null) return null;
          return (bytes: Uint8List.fromList(c.bytes), label: c.label);
        },
        onLoaded: (bytes, label) {
          _coverCache[key] = (bytes: bytes, label: label);
        },
      ),
    );
  }

  /// 打开 QQ/网易曲目封面详情窗（懒取字节并缓存回主窗）。
  void _openTrackCoverDetail(int i) {
    if (_trackCands.isEmpty) return;
    final idx = i.clamp(0, _trackCands.length - 1);
    final cand = _trackCands[idx];
    setState(() => _trackSel = idx);
    final key = _trackCoverKey(cand);
    final hit = _coverCache[key];
    showDialog<void>(
      context: context,
      builder: (_) => CoverDetailDialog(
        header:
            '${cand.trackName} — ${cand.artistName.isEmpty ? '未知歌手' : cand.artistName}',
        metaLines: [
          '来源 ${cand.source}',
          '专辑 ${cand.albumName.isEmpty ? '未知' : cand.albumName}'
              '${cand.durationSec != null ? ' · ${_fmtDur(cand.durationSec!)}' : ''}',
          '匹配 ${cand.matchWeight.toStringAsFixed(2)}${idx == 0 ? ' · 最佳匹配' : ''}',
        ],
        initialBytes: hit?.bytes,
        initialLabel: hit?.label ?? '',
        load: () async {
          final c = await _svc.fetchTrackCover(cand);
          if (c == null) return null;
          return (bytes: Uint8List.fromList(c.bytes), label: c.label);
        },
        onLoaded: (bytes, label) {
          _coverCache[key] = (bytes: bytes, label: label);
        },
      ),
    );
  }

  static String _mbCoverKey(MbRecordingCandidate r) => 'mb:${r.releaseId}';
  static String _trackCoverKey(OnlineLyricCandidate c) =>
      't:${c.source}:${c.onlineId}';

  /// 标签页「查看」：歌词候选将回填的标签。
  void _openLyricTagDetail() {
    if (!_hasLyricCands) return;
    final idx = _lyricSel.clamp(0, _lyrics.length - 1);
    final c = _lyrics[idx];
    showDialog<void>(
      context: context,
      builder: (_) => TagDetailDialog(
        source: c.source,
        title: c.trackName,
        artist: c.artistName,
        album: c.albumName,
        metaLines: [
          if (c.durationSec != null) '时长 ${_fmtDur(c.durationSec!)}',
          '匹配 ${c.matchWeight.toStringAsFixed(2)}${idx == 0 ? ' · 最佳匹配' : ''}',
        ],
      ),
    );
  }

  /// 标签页「查看」：封面候选（MB 录音 / QQ·网易曲目）将回填的标签。
  void _openCoverTagDetail() {
    if (!_hasCoverCands) return;
    if (_coverIsMb) {
      final idx = _recSel.clamp(0, _recs.length - 1);
      final r = _recs[idx];
      showDialog<void>(
        context: context,
        builder: (_) => TagDetailDialog(
          source: OnlineMetaSource.mbCaa,
          title: r.title,
          artist: r.artist,
          album: r.releaseTitle ?? '',
          metaLines: [
            '匹配 ${r.matchWeight.toStringAsFixed(2)}${idx == 0 ? ' · 最佳匹配' : ''}',
          ],
        ),
      );
    } else {
      final idx = _trackSel.clamp(0, _trackCands.length - 1);
      final c = _trackCands[idx];
      showDialog<void>(
        context: context,
        builder: (_) => TagDetailDialog(
          source: c.source,
          title: c.trackName,
          artist: c.artistName,
          album: c.albumName,
          metaLines: [
            if (c.durationSec != null) '时长 ${_fmtDur(c.durationSec!)}',
            '匹配 ${c.matchWeight.toStringAsFixed(2)}${idx == 0 ? ' · 最佳匹配' : ''}',
          ],
        ),
      );
    }
  }

  /// 列表下方的细字状态（列表非空时的取数/无图提示）。
  Widget _statusLine(String text, ColorScheme cs) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text,
          style: TextStyle(color: cs.error, fontSize: 12),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
    );
  }

  /// 候选行尾的「查看」按钮（打开独立详情窗）。
  Widget _detailButton(VoidCallback? onPressed, String tooltip) => IconButton(
        icon: const Icon(Icons.open_in_new, size: 18),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      );

  Widget _lyricTab() {
    if (_lyricSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_lyrics.isEmpty) {
      return Center(
        child: Text(_lyricError.isEmpty ? '暂无候选，换关键词重搜' : _lyricError,
            textAlign: TextAlign.center),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: RadioGroup<int>(
            groupValue: _lyricSel,
            onChanged: (v) => setState(() => _lyricSel = v ?? 0),
            child: ListView.builder(
              itemCount: _lyrics.length,
              itemBuilder: (c, i) {
                final e = _lyrics[i];
                final best = i == 0;
                return RadioListTile<int>(
                  dense: true,
                  value: i,
                  controlAffinity: ListTileControlAffinity.leading,
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
                  secondary:
                      _detailButton(() => _openLyricDetail(i), '查看歌词详情'),
                );
              },
            ),
          ),
        ),
        _statusLine(_lyricError, cs),
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
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: RadioGroup<int>(
            groupValue: _recSel,
            onChanged: (v) => setState(() => _recSel = v ?? 0),
            child: ListView.builder(
              itemCount: _recs.length,
              itemBuilder: (c, i) {
                final e = _recs[i];
                return RadioListTile<int>(
                  dense: true,
                  value: i,
                  controlAffinity: ListTileControlAffinity.leading,
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
                  secondary:
                      _detailButton(() => _openMbCoverDetail(i), '查看封面详情'),
                );
              },
            ),
          ),
        ),
        _statusLine(_coverError, cs),
      ],
    );
  }

  /// QQ/网易封面页：曲目候选（与歌词页同源），行尾「查看」开大图详情。
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
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: RadioGroup<int>(
            groupValue: _trackSel,
            onChanged: (v) => setState(() => _trackSel = v ?? 0),
            child: ListView.builder(
              itemCount: _trackCands.length,
              itemBuilder: (c, i) {
                final e = _trackCands[i];
                return RadioListTile<int>(
                  dense: true,
                  value: i,
                  controlAffinity: ListTileControlAffinity.leading,
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
                  secondary: _detailButton(
                      () => _openTrackCoverDetail(i), '查看封面详情'),
                );
              },
            ),
          ),
        ),
        _statusLine(_coverError, cs),
      ],
    );
  }

  /// 标签页：像前两页一样点选「回填来源」，行尾查看对应候选详情，
  /// 底部「保存标签」执行回填。
  Widget _tagTab() {
    final lyricCand =
        _hasLyricCands ? _lyrics[_lyricSel.clamp(0, _lyrics.length - 1)] : null;
    final rec = _coverIsMb && _recs.isNotEmpty
        ? _recs[_recSel.clamp(0, _recs.length - 1)]
        : null;
    final track = !_coverIsMb && _trackCands.isNotEmpty
        ? _trackCands[_trackSel.clamp(0, _trackCands.length - 1)]
        : null;
    final coverSubtitle = rec != null
        ? '${rec.title} — ${rec.artist.isEmpty ? '未知歌手' : rec.artist}'
        : track != null
            ? '${track.trackName} — ${track.artistName.isEmpty ? '未知歌手' : track.artistName}'
            : '先在封面页搜索';
    return RadioGroup<_TagSource>(
      groupValue: _activeTagSource,
      onChanged: (v) => setState(() => _tagSource = v ?? _TagSource.lyrics),
      child: ListView(
        children: [
          const Text('选择回填来源（点选后底部保存；空值不覆盖本地，扫描不再覆盖已回填行）。'),
          const SizedBox(height: 4),
          RadioListTile<_TagSource>(
            dense: true,
            value: _TagSource.lyrics,
            controlAffinity: ListTileControlAffinity.leading,
            enabled: _hasLyricCands,
            title: const Text('用歌词候选回填'),
            subtitle: Text(lyricCand != null
                ? '${lyricCand.trackName} — ${lyricCand.artistName}'
                : '先在歌词页搜索'),
            secondary: _detailButton(
              _hasLyricCands ? _openLyricTagDetail : null,
              '查看标签详情',
            ),
          ),
          RadioListTile<_TagSource>(
            dense: true,
            value: _TagSource.cover,
            controlAffinity: ListTileControlAffinity.leading,
            enabled: _hasCoverCands,
            title: Text(_coverIsMb
                ? '用封面候选（MB录音）回填'
                : '用封面候选（${_coverSource.label}）回填'),
            subtitle: Text(coverSubtitle),
            secondary: _detailButton(
              _hasCoverCands ? _openCoverTagDetail : null,
              '查看标签详情',
            ),
          ),
          const Divider(),
          const Text('说明：只回填标题/歌手/专辑，不含流派/年份/曲目号；封面/歌词请在前两页单独保存。'),
        ],
      ),
    );
  }

  static String _fmtDur(double sec) {
    final s = sec.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

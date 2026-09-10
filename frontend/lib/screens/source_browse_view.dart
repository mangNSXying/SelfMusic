import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../services/server_settings.dart';
import '../widgets/song_tile.dart';

/// 源内浏览组件（文件夹式导航）：在 AppContent 内容区原地渲染。
///
/// - 直连源：本地索引（扫描后）检索，提供「扫描」按钮建立/刷新本地索引。
/// - 服务端代理源：从后端 /api 拉取整体库（异步），无「扫描」按钮。
class SourceBrowseView extends StatefulWidget {
  final String sourceKey;
  const SourceBrowseView({super.key, required this.sourceKey});

  @override
  State<SourceBrowseView> createState() => _SourceBrowseViewState();
}

class _SourceBrowseViewState extends State<SourceBrowseView> {
  String _query = '';
  bool _scanning = false;
  bool _loading = false;
  List<Song> _songs = [];

  bool get _isProxy =>
      context.read<DirectSourceManager>().isProxy(widget.sourceKey);

  /// 代理模式但「服务端」地址尚未配置。
  bool get _serverUnconfigured =>
      _isProxy && context.read<ServerSettings>().baseUrl.isEmpty;

  @override
  void initState() {
    super.initState();
    if (_isProxy && !_serverUnconfigured) _loadProxy();
  }

  Future<void> _loadProxy() async {
    if (_serverUnconfigured) return;
    setState(() => _loading = true);
    try {
      final direct = context.read<DirectSourceManager>();
      final songs =
          await direct.fetchSongsFor(widget.sourceKey, query: _query);
      if (mounted) setState(() => _songs = songs);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('拉取失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scan(MusicSource source) async {
    setState(() => _scanning = true);
    final lib = context.read<LibraryProvider>();
    final manager = context.read<DirectSourceManager>();
    try {
      final summary = await manager.scanSource(widget.sourceKey);
      // 扫描后刷新全局合并库，使歌曲/专辑/歌手栏目同步出现该源曲目。
      await lib.loadSongs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  '扫描完成：新增 ${summary.added} 首，共 ${summary.total} 首')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('扫描失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _play(BuildContext c, MusicSource source, List<Song> songs, int i) {
    final player = c.read<PlayerProvider>();
    player.playQueue(songs, index: i, source: source);
    c.read<NavigationProvider>().openPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final direct = context.watch<DirectSourceManager>();
    final source = direct.sourceByKey(widget.sourceKey);
    if (source == null) {
      return const Center(child: Text('源不存在'));
    }
    final isProxy = _isProxy;
    final songs = isProxy
        ? _songs
        : direct.songsOf(widget.sourceKey, query: _query);
    final count = isProxy ? _songs.length : direct.countOf(widget.sourceKey);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回播放源',
                onPressed: nav.exitSource,
              ),
              const SizedBox(width: 4),
              Icon(Icons.folder_outlined,
                  size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (isProxy)
                TextButton.icon(
                  onPressed: _loading ? null : _loadProxy,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('刷新'),
                )
              else
                FilledButton.icon(
                  onPressed: _scanning ? null : () => _scan(source),
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('扫描'),
                ),
            ],
          ),
        ),
        const Divider(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索该源曲目（标题/歌手/专辑）',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    setState(() => _query = v);
                    if (isProxy) _loadProxy();
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              isProxy
                  ? '服务端代理 · 共 $count 首'
                  : '已索引 $count 首 · ${source.name}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        const Divider(height: 16),
        if (direct.error != null && !isProxy)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(direct.error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : songs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.library_music_outlined,
                              size: 64,
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.4)),
                          const SizedBox(height: 12),
                          Text(
                            _serverUnconfigured
                                ? '代理模式需要先配置后端地址\n请到设置 → 「服务端」填写后端地址'
                                : (isProxy
                                    ? '服务端暂无可播放曲目'
                                    : '暂无索引曲目，点击"扫描"建立本地索引'),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: songs.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (c, i) => SongTile(
                        song: songs[i],
                        source: source,
                        onPlay: () => _play(c, source, songs, i),
                      ),
                    ),
        ),
      ],
    );
  }
}
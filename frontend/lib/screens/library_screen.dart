import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../theme/app_theme.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';

/// 内容区：根据导航 Section / 设置分区 / 播放页动态渲染对应页面。
class AppContent extends StatelessWidget {
  const AppContent({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();

    if (nav.playerView) {
      return const PlayerScreen();
    }
    if (nav.inSettings) {
      return const SettingsScreen();
    }

    switch (nav.section) {
      case NavSection.songs:
        return const _SongsView();
      case NavSection.albums:
        return const _AlbumsView();
      case NavSection.sources:
        return const SourcesScreen();
      case NavSection.playlists:
      case NavSection.liked:
      case NavSection.artists:
        return _Placeholder(section: nav.section);
    }
  }
}

/// 占位页：后端尚无对应数据接口，先展示骨架提示。
class _Placeholder extends StatelessWidget {
  final NavSection section;
  const _Placeholder({required this.section});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(section.icon, size: 72, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text('${section.label}功能开发中',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('该模块的后端数据接入尚未完成，敬请期待',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5))),
        ],
      ),
    );
  }
}

class _SongsView extends StatelessWidget {
  const _SongsView();

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final player = context.read<PlayerProvider>();

    // 依据全局搜索词加载（由 LibraryProvider 配合）。
    final songs = _filter(lib.songs, nav.search);
    final source = context.read<LibraryProvider>().source;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(lib.error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: songs.isEmpty
              ? _EmptyHint(onRefresh: () => lib.loadSongs(query: nav.search.isEmpty ? null : nav.search))
              : RefreshIndicator(
                  onRefresh: () => lib.loadSongs(query: nav.search.isEmpty ? null : nav.search),
                  child: ListView.separated(
                    itemCount: songs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                    itemBuilder: (c, i) {
                      final s = songs[i];
                      return ListTile(
                        leading: Icon(Icons.music_note, color: Theme.of(c).colorScheme.primary),
                        title: Text(s.title),
                        subtitle: Text('${s.artist ?? "Unknown"} · ${s.source} · ${s.format ?? ""}'),
                        trailing: Text(s.duration != null ? _fmts(s.duration!) : ''),
                        isThreeLine: false,
                        onTap: () {
                          player.playQueue(songs, index: i, source: source);
                          context.read<NavigationProvider>().openPlayer();
                        },
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  List<Song> _filter(List<Song> songs, String q) {
    if (q.trim().isEmpty) return songs;
    final qq = q.trim().toLowerCase();
    return songs.where((s) =>
        (s.title.toLowerCase().contains(qq)) ||
        (s.artist?.toLowerCase().contains(qq) ?? false)).toList();
  }

  String _fmts(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _AlbumsView extends StatelessWidget {
  const _AlbumsView();

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final albums = _filter(lib.albums, nav.search);
    final source = context.read<LibraryProvider>().source;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(lib.error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: albums.isEmpty
              ? _EmptyHint(onRefresh: () => lib.loadAlbums(query: nav.search.isEmpty ? null : nav.search))
              : RefreshIndicator(
                  onRefresh: () => lib.loadAlbums(query: nav.search.isEmpty ? null : nav.search),
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.72,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (c, i) {
                      final a = albums[i];
                      return _AlbumCard(album: a, source: source);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  List<Album> _filter(List<Album> albums, String q) {
    if (q.trim().isEmpty) return albums;
    final qq = q.trim().toLowerCase();
    return albums.where((a) =>
        a.album.toLowerCase().contains(qq) ||
        (a.artist.toLowerCase().contains(qq))).toList();
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  final dynamic source;
  const _AlbumCard({required this.album, required this.source});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final songs = await source.fetchAlbumSongs(album.id);
        if (!context.mounted) return;
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (c) => _AlbumSongsSheet(album: album, songs: songs),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.album, size: 48, color: colorScheme.primary.withValues(alpha: 0.6)),
            ),
          ),
          const SizedBox(height: 8),
          Text(album.album, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text('${album.artist} · ${album.trackCount}首', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}

class _AlbumSongsSheet extends StatelessWidget {
  final Album album;
  final List<Song> songs;
  const _AlbumSongsSheet({required this.album, required this.songs});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (c, scrollCtrl) {
        final player = context.read<PlayerProvider>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(album.album,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollCtrl,
                itemCount: songs.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                itemBuilder: (c, i) {
                  final s = songs[i];
                  return ListTile(
                    leading: Icon(Icons.music_note, color: Theme.of(c).colorScheme.primary),
                    title: Text(s.title),
                    subtitle: Text(s.artist ?? 'Unknown'),
                    trailing: Text(s.duration != null ? '${s.duration}s' : ''),
                    onTap: () {
                      Navigator.of(c).pop();
                      player.playQueue(songs, index: i);
                      context.read<NavigationProvider>().openPlayer();
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyHint({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_off, size: 72, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('暂无内容'),
          const SizedBox(height: 8),
          TextButton.icon(icon: const Icon(Icons.refresh), label: const Text('刷新/扫描'), onPressed: onRefresh),
        ],
      ),
    );
  }
}

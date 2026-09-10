import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';
import 'source_browse_view.dart';

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
    // 播放源「文件夹」子级：源内浏览（原地切换）。
    if (nav.section == NavSection.sources && nav.browsingSourceKey != null) {
      return SourceBrowseView(sourceKey: nav.browsingSourceKey!);
    }

    switch (nav.section) {
      case NavSection.songs:
        return const _SongsView();
      case NavSection.albums:
        return const _AlbumsView();
      case NavSection.sources:
        return const SourcesScreen();
      case NavSection.artists:
        return const _ArtistsView();
      case NavSection.playlists:
      case NavSection.liked:
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

class _SongsView extends StatefulWidget {
  const _SongsView();

  @override
  State<_SongsView> createState() => _SongsViewState();
}

class _SongsViewState extends State<_SongsView> {
  @override
  void initState() {
    super.initState();
    final lib = context.read<LibraryProvider>();
    if (lib.songs.isEmpty && !lib.loading) {
      final nav = context.read<NavigationProvider>();
      lib.loadSongs(query: nav.search.isEmpty ? null : nav.search);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final player = context.read<PlayerProvider>();

    // 依据全局搜索词加载（由 LibraryProvider 配合）。
    final songs = _filter(lib.songs, nav.search);

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
                      return SongTile(
                        song: s,
                        source: lib.sourceFor(s.sourceKey) ?? lib.source,
                        onPlay: () {
                          player.playQueue(songs, index: i, source: lib.source);
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
}

class _AlbumsView extends StatefulWidget {
  const _AlbumsView();

  @override
  State<_AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<_AlbumsView> {
  @override
  void initState() {
    super.initState();
    final lib = context.read<LibraryProvider>();
    if (lib.albums.isEmpty && !lib.loading) {
      lib.loadAlbums(
          query: context.read<NavigationProvider>().search.isEmpty ? null : context.read<NavigationProvider>().search);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final albums = _filter(lib.albums, nav.search);

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
                    itemBuilder: (c, i) => _AlbumCard(album: albums[i]),
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
  const _AlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final lib = context.read<LibraryProvider>();
        var songs = lib.albumSongs(album);
        if (songs.isEmpty) {
          songs = await lib.source.fetchAlbumSongs(album.id);
        }
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
              clipBehavior: Clip.antiAlias,
              child: album.coverPath != null
                  ? Image.file(File(album.coverPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(Icons.album,
                          size: 48,
                          color: colorScheme.primary.withValues(alpha: 0.6)))
                  : Icon(Icons.album,
                      size: 48, color: colorScheme.primary.withValues(alpha: 0.6)),
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
        final lib = context.read<LibraryProvider>();
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
                  return SongTile(
                    song: s,
                    source: lib.sourceFor(s.sourceKey) ?? lib.source,
                    onPlay: () {
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

class _ArtistsView extends StatefulWidget {
  const _ArtistsView();

  @override
  State<_ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<_ArtistsView> {
  @override
  void initState() {
    super.initState();
    final lib = context.read<LibraryProvider>();
    if (lib.artists.isEmpty && !lib.loading) {
      lib.loadArtists(
          query: context.read<NavigationProvider>().search.isEmpty ? null : context.read<NavigationProvider>().search);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final lib = context.watch<LibraryProvider>();
    final artists = _filter(lib.artists, nav.search);

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(lib.error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: artists.isEmpty
              ? _EmptyHint(onRefresh: () => lib.loadArtists(query: nav.search.isEmpty ? null : nav.search))
              : RefreshIndicator(
                  onRefresh: () => lib.loadArtists(query: nav.search.isEmpty ? null : nav.search),
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.8,
                    ),
                    itemCount: artists.length,
                    itemBuilder: (c, i) => _ArtistCard(artist: artists[i]),
                  ),
                ),
        ),
      ],
    );
  }

  List<Artist> _filter(List<Artist> artists, String q) {
    if (q.trim().isEmpty) return artists;
    final qq = q.trim().toLowerCase();
    return artists.where((a) => a.name.toLowerCase().contains(qq)).toList();
  }
}

class _ArtistCard extends StatelessWidget {
  final Artist artist;
  const _ArtistCard({required this.artist});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        final lib = context.read<LibraryProvider>();
        final songs = lib.artistSongs(artist);
        if (!context.mounted) return;
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (c) => _ArtistSongsSheet(artist: artist, songs: songs),
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
              clipBehavior: Clip.antiAlias,
              child: artist.coverPath != null
                  ? Image.file(File(artist.coverPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(Icons.person,
                          size: 48,
                          color: colorScheme.primary.withValues(alpha: 0.6)))
                  : Icon(Icons.person,
                      size: 48, color: colorScheme.primary.withValues(alpha: 0.6)),
            ),
          ),
          const SizedBox(height: 8),
          Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text('${artist.songCount}首 · ${artist.albumCount}张专辑', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}

class _ArtistSongsSheet extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;
  const _ArtistSongsSheet({required this.artist, required this.songs});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (c, scrollCtrl) {
        final player = context.read<PlayerProvider>();
        final lib = context.read<LibraryProvider>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(artist.name,
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
                  return SongTile(
                    song: s,
                    source: lib.sourceFor(s.sourceKey) ?? lib.source,
                    onPlay: () {
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
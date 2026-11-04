import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/theme/app_theme.dart';

/// 内存状态存储：模拟 AppSettings.navigationState 的同步读写。
class _Store {
  String? value;

  NavigationProvider create() => NavigationProvider(
        readState: () => value,
        writeState: (state) => value = state,
      );
}

Song _song() => Song(
      id: 1,
      sourceKey: 'local:test',
      title: '曲目',
      source: 'local',
      sourceRef: 'a.mp3',
      fileSize: 100,
      duration: 120,
    );

void main() {
  test('冷启动恢复歌单详情：首屏仍是播放页，下滑后看到原歌单', () {
    final store = _Store();
    store.create()
      ..select(NavSection.playlists)
      ..enterPlaylist(42);

    final restored = store.create();
    expect(restored.section, NavSection.playlists);
    expect(restored.browsingPlaylistId, 42);
    // 首页恒为播放页（播放页根返回不动作），内容页藏在下面。
    expect(restored.playerView, isTrue);
    expect(restored.homeBand, NavigationProvider.homePlayerBand);
    expect(restored.backToPrevious(), isFalse);
    expect(restored.browsingPlaylistId, 42);

    restored.closePlayer();
    expect(restored.browsingPlaylistId, 42);
    expect(restored.backToPrevious(), isTrue);
    expect(restored.browsingPlaylistId, isNull);
  });

  test('恢复多级内容栈：源内目录 + 设置', () {
    final store = _Store();
    final nav = store.create()
      ..select(NavSection.sources)
      ..enterSource('webdav:nas')
      ..setSourceDir('Music/Rock')
      ..openSettings(SettingsItem.appearance);
    expect(nav.contentRoutes, hasLength(4));

    final restored = store.create();
    expect(restored.section, NavSection.sources);
    expect(restored.browsingSourceKey, 'webdav:nas');
    expect(restored.sourceDir, 'Music/Rock');
    expect(restored.settings, SettingsItem.appearance);
    expect(restored.contentRoutes, hasLength(4));
  });

  test('专辑/歌手详情只恢复元信息，歌曲由详情页从曲库解析', () {
    final album = Album(
      id: 1,
      artist: '歌手',
      album: '专辑',
      groupKey: 'album\x00专辑',
      trackCount: 1,
      totalDuration: 120,
      coverPath: '/covers/album.jpg',
    );
    const artist = Artist(
      name: '歌手',
      songCount: 1,
      albumCount: 1,
      identityKey: 'artist-key',
    );

    final albumStore = _Store();
    albumStore.create()
      ..select(NavSection.albums)
      ..enterAlbum(album, [_song()]);
    final restoredAlbum = albumStore.create();
    final albumRoute = restoredAlbum.contentTop as AlbumDetailRoute;
    expect(albumRoute.album.groupKey, album.groupKey);
    expect(albumRoute.album.coverPath, '/covers/album.jpg');
    expect(albumRoute.songs, isEmpty);

    final artistStore = _Store();
    artistStore.create()
      ..select(NavSection.artists)
      ..enterArtist(artist, [_song()]);
    final restoredArtist = artistStore.create();
    final artistRoute = restoredArtist.contentTop as ArtistDetailRoute;
    expect(artistRoute.artist.identityKey, 'artist-key');
    expect(artistRoute.songs, isEmpty);
  });

  test('退出详情会覆盖旧状态，下次启动不再恢复', () {
    final store = _Store();
    store.create()
      ..select(NavSection.playlists)
      ..enterPlaylist(7)
      ..exitPlaylist();

    final restored = store.create();
    expect(restored.section, NavSection.playlists);
    expect(restored.browsingPlaylistId, isNull);
  });

  test('损坏、旧版本或未知路由类型不会污染内容栈', () {
    for (final raw in [
      'not-json',
      jsonEncode({'v': 0, 'section': 'playlists', 'routes': []}),
    ]) {
      final nav = NavigationProvider(
        readState: () => raw,
        writeState: (_) {},
      );
      expect(nav.section, NavSection.songs);
      expect(nav.contentRoutes, isEmpty);
    }

    final raw = jsonEncode({
      'v': 1,
      'section': 'sources',
      'routes': [
        {'t': 'source', 'key': 'smb:nas', 'dir': ''},
        {'t': 'unknown'},
        {'t': 'settings', 'item': 'general'},
      ],
    });
    final nav = NavigationProvider(
      readState: () => raw,
      writeState: (_) {},
    );
    expect(nav.section, NavSection.sources);
    expect(nav.contentRoutes, hasLength(1));
    expect(nav.contentTop, isA<SourceBrowseRoute>());
  });
}

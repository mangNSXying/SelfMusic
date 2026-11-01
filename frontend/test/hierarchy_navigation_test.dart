import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/theme/app_theme.dart';

Album _album(int id, String name) => Album(
      id: id,
      artist: '歌手',
      album: name,
      groupKey: 'album\x00$name',
      trackCount: 1,
      totalDuration: 100,
    );

const _artist =
    Artist(name: '歌手', songCount: 10, albumCount: 2, identityKey: 'artist-key');
const _member =
    Artist(name: '成员', songCount: 3, albumCount: 1, identityKey: 'member-key');

void main() {
  group('层级返回 v2', () {
    test('首页是根：展开时返回不弹下面看不见的内容栈', () {
      final nav = NavigationProvider()..select(NavSection.songs);
      nav.enterPlaylist(3);

      nav.openPlayer();
      expect(nav.playerView, isTrue);
      expect(nav.browsingPlaylistId, 3, reason: '首页只是封面，不弹内容栈');

      // 首页根：返回 false（调用方转后台/不动作），歌单仍保留。
      expect(nav.backToPrevious(), isFalse);
      expect(nav.browsingPlaylistId, 3);

      // 首页子页先回播放页；再返回才离开首页。
      nav.reportHomeBand(2);
      expect(nav.backToPrevious(), isTrue);
      expect(nav.homeBand, 1);
      expect(nav.backToPrevious(), isFalse);

      // 收起首页后，返回作用在内容栈上。
      nav.closePlayer();
      expect(nav.backToPrevious(), isTrue);
      expect(nav.browsingPlaylistId, isNull);
    });

    test('设置压在详情上，返回回到原详情', () {
      final nav = NavigationProvider()
        ..select(NavSection.artists)
        ..enterArtist(_artist, const []);

      nav.openSettings(SettingsItem.general);
      expect(nav.contentTop, isA<SettingsRoute>());

      expect(nav.backToPrevious(), isTrue);
      expect(nav.settings, isNull);
      expect(nav.details.single, isA<ArtistDetailRoute>());
    });

    test('设置分区同层替换，不叠多层', () {
      final nav = NavigationProvider()..openSettings(SettingsItem.appearance);
      nav.openSettings(SettingsItem.songs);

      expect(nav.contentRoutes, hasLength(1));
      expect(nav.settings, SettingsItem.songs);
      expect(nav.backToPrevious(), isTrue);
      expect(nav.contentRoutes, isEmpty);
    });

    test('点回栈内已有的歌手：回退到那一层，不重复压栈', () {
      final nav = NavigationProvider()
        ..select(NavSection.artists)
        ..enterArtist(_artist, const [])
        ..enterAlbum(_album(1, '专辑一'), const [])
        ..enterArtist(_artist, const []);

      expect(nav.contentRoutes, hasLength(1));
      expect(nav.contentTop, isA<ArtistDetailRoute>());

      nav.enterArtist(_member, const []);
      nav.enterArtist(_artist, const []);
      expect(nav.contentTop, isA<ArtistDetailRoute>());
      expect((nav.contentTop as ArtistDetailRoute).artist.name, '歌手');
    });

    test('歌曲信息是 L2 内容栈：明细/总览逐层返回，设置在其下', () {
      final nav = NavigationProvider()..select(NavSection.songs);

      nav.openLibraryInfo(LibraryInfoPage.overview);
      expect(nav.libraryInfoPage, LibraryInfoPage.overview);
      expect(nav.playerView, isFalse);

      nav.openLibraryInfo(LibraryInfoPage.meta);
      expect(nav.libraryInfoPage, LibraryInfoPage.meta);
      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.libraryInfoPage, LibraryInfoPage.overview);

      // 从总览返回：回到内容基座，不直接离家。
      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.contentRoutes, isEmpty);
      expect(nav.playerView, isFalse);
      expect(nav.backToPrevious(), isTrue);
      expect(nav.playerView, isTrue);

      // 设置 + 歌曲信息：返回先弹歌曲信息，再弹设置。
      nav.closePlayer();
      nav.openSettings(SettingsItem.general);
      nav.openLibraryInfo(LibraryInfoPage.overview);
      expect(nav.libraryInfoPage, LibraryInfoPage.overview);
      expect(nav.backToPrevious(keepSearch: true), isTrue);
      expect(nav.libraryInfoPage, isNull);
      expect(nav.settings, SettingsItem.general);

      // 侧栏“歌曲信息”从明细回总览：收掉子栈，不叠总览。
      nav.openLibraryInfo(LibraryInfoPage.meta);
      nav.openLibraryInfo(LibraryInfoPage.overview);
      expect(nav.contentRoutes.whereType<LibraryInfoRoute>(), hasLength(1));
      expect(nav.libraryInfoPage, LibraryInfoPage.overview);
    });

    test('宽屏队列面板是 chrome：不消费返回，也不影响内容栈', () {
      final nav = NavigationProvider()..select(NavSection.songs);
      nav.openQueue();
      expect(nav.backToPrevious(), isTrue);
      expect(nav.queueOpen, isTrue);
      expect(nav.playerView, isTrue);
    });
  });
}

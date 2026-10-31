import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/layout/detail_target.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/widgets/detail_presentation.dart';
import 'package:selfmusic/widgets/section_swipe.dart';

Album _album(String key) => Album(
      id: 1,
      artist: '歌手',
      album: key,
      groupKey: key,
      trackCount: 0,
      totalDuration: 0,
    );

const _artist =
    Artist(name: '歌手', songCount: 0, albumCount: 0, identityKey: 'artist-key');

void main() {
  group('DetailTarget 去重口径', () {
    test('专辑只看栈顶，歌手看整栈；歌单/播放源看既有路由字段', () {
      final nav = NavigationProvider();
      final a1 = _album('专辑一');
      final a2 = _album('专辑二');

      expect(AlbumTarget(a1, const []).isShowing(nav), isFalse);

      nav.enterAlbum(a1, const []);
      expect(AlbumTarget(a1, const []).isShowing(nav), isTrue);
      // 嵌套后专辑一不再是栈顶 → 不再算"正在显示"（与旧 _showingAlbum 一致）。
      nav.enterArtist(_artist, const []);
      nav.enterAlbum(a1, const []);
      expect(AlbumTarget(a1, const []).isShowing(nav), isTrue);
      nav.exitDetail();
      expect(AlbumTarget(a1, const []).isShowing(nav), isFalse);
      // 歌手在栈里任意一层都算（"歌手 → 专辑"嵌套时点回同一歌手）。
      expect(const ArtistTarget(_artist, []).isShowing(nav), isTrue);

      nav.enterPlaylist(7);
      expect(const PlaylistTarget(7).isShowing(nav), isTrue);
      expect(const PlaylistTarget(8).isShowing(nav), isFalse);

      nav.enterSource('local:test');
      expect(const SourceTarget('local:test').isShowing(nav), isTrue);
      expect(const SourceTarget('local:other').isShowing(nav), isFalse);

      // 换目标后旧目标不再命中。
      nav.enterSource('local:other');
      expect(const SourceTarget('local:test').isShowing(nav), isFalse);
      expect(const SourceTarget('local:other').isShowing(nav), isTrue);

      nav.enterAlbum(a2, const []);
      expect(AlbumTarget(a1, const []).isShowing(nav), isFalse);
    });
  });

  group('DetailPresentationShell', () {
    Widget app(DetailPresentation presentation) => ChangeNotifierProvider(
          create: (_) => NavigationProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: DetailPresentationShell(
                presentation: presentation,
                child: const Text('详情'),
              ),
            ),
          ),
        );

    testWidgets('page 保留分组横滑；pane/overlay 不包且自绘不透明底', (tester) async {
      await tester.pumpWidget(app(DetailPresentation.page));
      expect(find.byType(SectionSwipe), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);

      for (final presentation in [
        DetailPresentation.pane,
        DetailPresentation.overlay,
      ]) {
        await tester.pumpWidget(app(presentation));
        expect(find.byType(SectionSwipe), findsNothing,
            reason: '$presentation 不应再套一层横滑');
        final bg =
            Theme.of(tester.element(find.text('详情'))).scaffoldBackgroundColor;
        final materials = tester
            .widgetList<Material>(find.byType(Material))
            .where((m) => m.color == bg);
        expect(materials, isNotEmpty,
            reason: '$presentation 需要不透明底，换详情时不透出上一页');
        expect(find.text('详情'), findsOneWidget);
      }
    });
  });
}
